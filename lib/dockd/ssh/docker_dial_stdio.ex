defmodule Dockd.Ssh.DockerDialStdio do
  @moduledoc """
  Manages the shell script that wraps `docker system dial-stdio` on a remote
  SSH host and translates non-zero exits into HTTP 502 responses.

  The script lives on the *remote* SSH host. This module gives you three
  decoupled capabilities:

    * **Render** the bundled EEx template to a binary in memory
      (`render_script/1`) so you can inspect or customise it.
    * **Generate** the rendered template to disk — see the
      `dockd ssh dial_stdio_script generate` command
      (`mix dockd ssh dial_stdio_script generate` in dev).
    * **Install** any script source to a remote host (`install/3`). The
      source can be an explicit path, a binary held in memory, or `:default`
      (render the bundled template and stream it to the host without ever
      touching local disk).

  ## Responsibilities

    - Locate the bundled EEx template (`template_path/0`)
    - Render the template to a binary (`render_script/1`)
    - Publish the canonical remote install location (`default_remote_path/0`)
    - Deploy a script (path or in-memory content) via `scp`/`ssh`
      (`install/3`)

  ## Why this exists

  When a remote `dial-stdio` invocation fails, the SSH channel just closes with
  no signal at the HTTP layer. The bundled wrapper inspects the exit status with
  `$?` and writes a real HTTP/1.1 502 response when the wrapped command produced
  no output, so the client sees a typed HTTP error instead of an opaque EOF.

  ## Tradeoffs

    * The wrapper buffers `dial-stdio`'s stdout through a tempfile so it can
      decide - after the wrapped command exits - whether to overlay a synthetic
      502. This loses streaming. Do not use the wrapper for streaming Docker
      endpoints (image pulls, build logs, attach/exec output) where mid-stream
      client-side detection already handles the failure mode.
    * The wrapper can only synthesize a 502 when `dial-stdio` produced *no*
      output before failing. Once any byte has crossed toward the client, the
      wrapper is a passthrough.

  ## Examples

      iex> path = Dockd.Ssh.DockerDialStdio.template_path()
      iex> File.exists?(path)
      true

      iex> script = Dockd.Ssh.DockerDialStdio.render_script()
      iex> String.starts_with?(script, "#!/bin/sh")
      true

  Deploy with the bundled CLI command:

      dockd ssh dial_stdio_script install user@host

  Or in dev, via the mix forwarder:

      mix dockd ssh dial_stdio_script install user@host

  Or programmatically with the bundled default (no local disk write):

      Dockd.Ssh.DockerDialStdio.install(:default, "user@host", [])
  """

  @type script_source :: Path.t() | {:content, binary()} | :default

  @template_filename "docker_dial_stdio_script.sh.eex"

  @doc """
  Returns the absolute path of the bundled EEx template on the *local*
  filesystem.

  The template lives in this application's `priv` directory.
  """
  @spec template_path() :: Path.t()
  def template_path do
    Path.join([:code.priv_dir(:dockd), "eex", @template_filename])
  end

  @doc """
  Back-compat alias for `template_path/0`. The bundled file is now an EEx
  template, but the path still names a file on disk that callers can read or
  copy as-is — the template has no expressions today.
  """
  @spec local_path() :: Path.t()
  def local_path, do: template_path()

  @doc """
  Renders the bundled EEx template to a binary.

  `assigns` is forwarded to `EEx.eval_file/2` under the `:assigns` key, so
  the template can reference values as `<%= @key %>`. The current template
  has no expressions, so passing assigns is harmless.
  """
  @spec render_script(keyword()) :: binary()
  def render_script(assigns \\ []) do
    EEx.eval_file(template_path(), assigns: assigns)
  end

  @doc """
  Returns the recommended absolute path of the deployed script on the *remote*
  SSH host.

  The canonical remote install path is `"/usr/local/bin/docker-stdio-bridge"`.
  This is the destination used by `dockd ssh dial_stdio_script install`
  (`mix dockd ssh dial_stdio_script install` in dev) when the caller does not
  pass `--remote-path`.

  ## Examples

      iex> Dockd.Ssh.DockerDialStdio.default_remote_path()
      "/usr/local/bin/docker-stdio-bridge"

  """
  @spec default_remote_path() :: Path.t()
  def default_remote_path, do: "/usr/local/bin/docker-stdio-bridge"

  @doc """
  Deploys a script to a remote SSH host.

  `script_source` is the first argument and selects how the script reaches
  the remote host:

    * `Path.t()` — `scp` the named local file, then `ssh chmod +x`, then
      verify.
    * `{:content, binary}` — stream the binary directly to the host over a
      single `ssh` invocation that writes the file, chmods it, and verifies
      it in one shell command. No local disk is touched.
    * `:default` — sugar for `{:content, render_script([])}`.

  ## Parameters

    * `script_source` — see above.
    * `user_at_host` — SSH destination in `user@host` form.
    * `opts` — keyword list:
      * `:remote_path` — destination path on the host. Defaults to
        `default_remote_path/0`.
      * `:identity` — passed through to `scp`/`ssh` as `-i`.
      * `:port` — SSH port (passed as `-P` to `scp` and `-p` to `ssh`).

  ## Returns

    * `{:ok, %{source: script_source(), remote_path: Path.t()}}` on success.
    * `{:error, message}` when any subprocess fails or verification fails.
  """
  @spec install(script_source(), String.t(), keyword()) ::
          {:ok, %{source: script_source(), remote_path: Path.t()}}
          | {:error, String.t()}
  def install(script_source, user_at_host, opts \\ [])

  def install(:default, user_at_host, opts) do
    install({:content, render_script([])}, user_at_host, opts)
  end

  def install({:content, content}, user_at_host, opts) when is_binary(content) do
    remote_path = Keyword.get(opts, :remote_path, default_remote_path())
    identity = Keyword.get(opts, :identity)
    port = Keyword.get(opts, :port)

    plan = build_content_plan(user_at_host, remote_path, identity, port)

    case run_content_plan(plan, content) do
      :ok -> {:ok, %{source: {:content, content}, remote_path: remote_path}}
      {:error, message} -> {:error, message}
    end
  end

  def install(script_path, user_at_host, opts) when is_binary(script_path) do
    remote_path = Keyword.get(opts, :remote_path, default_remote_path())
    identity = Keyword.get(opts, :identity)
    port = Keyword.get(opts, :port)

    plan = build_plan(script_path, user_at_host, remote_path, identity, port)

    case run_plan(plan) do
      :ok -> {:ok, %{source: script_path, remote_path: remote_path}}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Builds the ordered list of subprocess steps `install/3` runs for the
  path-based flow (scp + ssh chmod + verify).

  Each entry is a `{step_name, executable, args, check}` tuple. `check` is
  `:no_check` for steps that only care about exit status, or `:expect_ok` for
  the verification step (which additionally requires the literal `"ok"` to
  appear in stdout).
  """
  @spec build_plan(Path.t(), String.t(), Path.t(), String.t() | nil, String.t() | nil) ::
          [{atom(), String.t(), [String.t()], :no_check | :expect_ok}]
  def build_plan(local, user_at_host, remote_path, identity, port) do
    id_args = identity_arg(identity)

    [
      {:scp, "scp", id_args ++ port_arg(port, "-P") ++ [local, "#{user_at_host}:#{remote_path}"],
       :no_check},
      {:ssh_chmod, "ssh",
       id_args ++ port_arg(port, "-p") ++ [user_at_host, "chmod", "+x", remote_path], :no_check},
      {:ssh_verify, "ssh",
       id_args ++ port_arg(port, "-p") ++ [user_at_host, "[ -x #{remote_path} ] && echo ok"],
       :expect_ok}
    ]
  end

  @doc """
  Builds the single-step plan `install/3` runs for the in-memory content
  flow. The single `ssh` step writes the file, chmods it, and verifies it in
  one remote shell command; the file body arrives over stdin.

  Returns a one-element list shaped like `build_plan/5` entries so callers can
  introspect both flows uniformly.
  """
  @spec build_content_plan(String.t(), Path.t(), String.t() | nil, String.t() | nil) ::
          [{atom(), String.t(), [String.t()], :expect_ok}]
  def build_content_plan(user_at_host, remote_path, identity, port) do
    id_args = identity_arg(identity)

    remote_cmd =
      "cat > #{remote_path} && chmod +x #{remote_path} && [ -x #{remote_path} ] && echo ok"

    [
      {:ssh_pipe, "ssh", id_args ++ port_arg(port, "-p") ++ [user_at_host, remote_cmd],
       :expect_ok}
    ]
  end

  defp run_plan([]), do: :ok

  defp run_plan([step | rest]) do
    case execute_step(step) do
      :ok -> run_plan(rest)
      {:error, _} = err -> err
    end
  end

  defp execute_step({_step, cmd, args, check}) do
    case ElixirExec.capture([cmd | args]) do
      # `capture/2` reports a non-zero exit as `{:ok, _}`, so the status must be
      # checked explicitly or a failed step reads as a success.
      {:ok, %ElixirExec.Output{exit_status: 0} = output} ->
        verify_check(check, combined_output(output))

      {:ok, %ElixirExec.Output{} = output} ->
        {:error, combined_output(output)}

      {:error, reason} ->
        {:error, "subprocess failed: #{inspect(reason)}"}
    end
  end

  # `Output` keeps the two streams apart; the checks search one blob of text.
  defp combined_output(%ElixirExec.Output{stdout: stdout, stderr: stderr}) do
    IO.iodata_to_binary([stdout, stderr])
  end

  defp run_content_plan([{_step, cmd, args, check}], content) do
    case ElixirExec.run([cmd | args], stdin: true) do
      {:ok, conn} ->
        :ok = ElixirExec.write(conn, content)
        :ok = ElixirExec.write(conn, :eof)
        collect_content_output(conn, [], check)

      {:error, reason} ->
        {:error, "subprocess failed: #{inspect(reason)}"}
    end
  end

  defp collect_content_output(conn, acc, check) do
    case ElixirExec.read(conn, 30_000) do
      {:ok, {:stdout, data}} ->
        collect_content_output(conn, [acc, data], check)

      {:ok, {:stderr, data}} ->
        collect_content_output(conn, [acc, data], check)

      {:ok, {:exit, 0}} ->
        verify_check(check, IO.iodata_to_binary(acc))

      {:ok, {:exit, status}} ->
        {:error,
         "ssh exited with status #{inspect(status)}; output: " <>
           inspect(IO.iodata_to_binary(acc))}

      {:error, :timeout} ->
        {:error, "timed out waiting for ssh to finish writing remote script"}
    end
  end

  defp verify_check(:no_check, _output), do: :ok

  defp verify_check(:expect_ok, output) do
    if String.contains?(output, "ok") do
      :ok
    else
      {:error,
       "verification failed: expected stdout to contain \"ok\" but got: #{inspect(output)}"}
    end
  end

  defp identity_arg(nil), do: []
  defp identity_arg(identity), do: ["-i", identity]

  defp port_arg(nil, _flag), do: []
  defp port_arg(port, flag), do: [flag, port]
end
