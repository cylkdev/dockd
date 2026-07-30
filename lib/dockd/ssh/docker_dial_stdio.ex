defmodule Dockd.Ssh.DockerDialStdio do
  @moduledoc """
  Manages the shell script that wraps `docker system dial-stdio` on a remote
  SSH host and translates non-zero exits into HTTP 502 responses.

  The script lives on the *remote* SSH host. This module gives you three
  decoupled capabilities:

    * **Render** the bundled EEx template to a binary in memory
      (`render_script/1`) so you can inspect or customise it.
    * **Generate** the rendered template to disk — see
      `Dockd.Ssh.generate_script/2`.
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

  Deploy the bundled default to a host (no local disk write):

      Dockd.Ssh.DockerDialStdio.install(:default, "user@host", [])

  Or render it to disk first, then install that file:

      {:ok, %{path: path}} = Dockd.Ssh.generate_script("/tmp", [])
      Dockd.Ssh.DockerDialStdio.install(path, "user@host", [])
  """

  @type script_source :: Path.t() | {:content, binary()} | :default

  @template_filename "docker_dial_stdio_script.sh.eex"

  # BatchMode=yes turns "prompt on stdin" into "fail". A prompt has no terminal to
  # read from here, and in the content flow it competes with the script body.
  @default_ssh_opts ["-o", "BatchMode=yes"]
  @default_timeout 30_000
  @safe_remote_path ~r{^[A-Za-z0-9_./-]+$}

  @doc """
  Returns the absolute path of the bundled EEx template on the *local*
  filesystem.

  A named, opt-in call rather than a fallback inside `render_script/2`: it reads
  `:code.priv_dir/1`, so the value depends on where this build is installed.
  """
  @spec default_template_path() :: Path.t()
  def default_template_path do
    Path.join([:code.priv_dir(:dockd), "eex", @template_filename])
  end

  @doc """
  Renders the EEx template at `template_path` to a binary.

  `template_path` is a required argument — pass `default_template_path/0` for the
  bundled template. `assigns` is forwarded to `EEx.eval_file/2` under the
  `:assigns` key, so the template can reference values as `<%= @key %>`.
  """
  @spec render_script(Path.t(), keyword()) :: binary()
  def render_script(template_path, assigns \\ []) do
    EEx.eval_file(template_path, assigns: assigns)
  end

  @doc """
  Returns the recommended absolute path of the deployed script on the *remote*
  SSH host.

  The canonical remote install path is `"/usr/local/bin/docker-stdio-bridge"`.
  This is the destination `install/3` uses when the caller does not pass a
  `:remote_path` option.

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
    * `:default` — sugar for `{:content, render_script(default_template_path())}`.

  ## Parameters

    * `script_source` — see above.
    * `user_at_host` — SSH destination in `user@host` form.
    * `ssh_path` — absolute path to the `ssh` executable. Required.
    * `scp_path` — absolute path to the `scp` executable. Required.
    * `opts` — keyword list:
      * `:remote_path` — destination path on the host. Defaults to
        `default_remote_path/0`. Rejected unless it is an absolute path free of
        shell metacharacters, since it is interpolated into a remote command.
      * `:identity` — passed through to `scp`/`ssh` as `-i`.
      * `:port` — SSH port (passed as `-P` to `scp` and `-p` to `ssh`).
      * `:ssh_opts` — extra `-o` style flags. Defaults to
        `["-o", "BatchMode=yes"]`, which makes an unauthenticated host fail
        instead of prompting on stdin — a prompt here has no terminal to read
        from, and in the content flow it collides with the script body being
        written to stdin.
      * `:timeout` — milliseconds to wait for the remote write. Defaults to
        `30_000`.

  ## Returns

    * `{:ok, %{source: script_source(), remote_path: Path.t()}}` on success.
    * `{:error, message}` when any subprocess fails or verification fails.
  """
  @spec install(script_source(), String.t(), Path.t(), Path.t(), keyword()) ::
          {:ok, %{source: script_source(), remote_path: Path.t()}}
          | {:error, String.t()}
  def install(script_source, user_at_host, ssh_path, scp_path, opts \\ [])

  def install(:default, user_at_host, ssh_path, scp_path, opts) do
    content = render_script(default_template_path())
    install({:content, content}, user_at_host, ssh_path, scp_path, opts)
  end

  def install({:content, content}, user_at_host, ssh_path, _scp_path, opts)
      when is_binary(content) do
    with {:ok, ssh} <- require_executable(ssh_path, "ssh"),
         {:ok, remote_path} <- resolve_remote_path(opts) do
      plan =
        build_content_plan(
          user_at_host,
          remote_path,
          Keyword.get(opts, :identity),
          Keyword.get(opts, :port),
          ssh,
          Keyword.get(opts, :ssh_opts, @default_ssh_opts)
        )

      case run_content_plan(plan, content, Keyword.get(opts, :timeout, @default_timeout)) do
        :ok -> {:ok, %{source: {:content, content}, remote_path: remote_path}}
        {:error, message} -> {:error, message}
      end
    end
  end

  def install(script_path, user_at_host, ssh_path, scp_path, opts) when is_binary(script_path) do
    with {:ok, ssh} <- require_executable(ssh_path, "ssh"),
         {:ok, scp} <- require_executable(scp_path, "scp"),
         {:ok, remote_path} <- resolve_remote_path(opts) do
      plan =
        build_plan(
          script_path,
          user_at_host,
          remote_path,
          Keyword.get(opts, :identity),
          Keyword.get(opts, :port),
          ssh,
          scp,
          Keyword.get(opts, :ssh_opts, @default_ssh_opts)
        )

      case run_plan(plan) do
        :ok -> {:ok, %{source: script_path, remote_path: remote_path}}
        {:error, message} -> {:error, message}
      end
    end
  end

  defp require_executable(path, name) do
    with :ok <- Dockd.HostTool.executable(path, name, "installing over SSH") do
      {:ok, path}
    end
  end

  # `remote_path` is interpolated into a remote shell command, so a value with a
  # space, `;`, `$`, or a glob would be expanded by the remote shell.
  defp resolve_remote_path(opts) do
    path = Keyword.get(opts, :remote_path, default_remote_path())

    cond do
      not is_binary(path) or path === "" ->
        {:error, "remote_path must be a non-empty string, got: #{inspect(path)}"}

      Path.type(path) !== :absolute ->
        {:error, "remote_path must be an absolute path, got: #{path}"}

      not Regex.match?(@safe_remote_path, path) ->
        {:error,
         "remote_path must contain only letters, digits, and the characters _.-/ " <>
           "(it is interpolated into a remote shell command), got: #{path}"}

      true ->
        {:ok, path}
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
  @spec build_plan(
          Path.t(),
          String.t(),
          Path.t(),
          String.t() | nil,
          String.t() | nil,
          Path.t(),
          Path.t(),
          [String.t()]
        ) :: [{atom(), String.t(), [String.t()], :no_check | :expect_ok}]
  def build_plan(local, user_at_host, remote_path, identity, port, ssh, scp, ssh_opts) do
    base = identity_arg(identity) ++ ssh_opts

    [
      {:scp, scp, base ++ port_arg(port, "-P") ++ [local, "#{user_at_host}:#{remote_path}"],
       :no_check},
      {:ssh_chmod, ssh,
       base ++ port_arg(port, "-p") ++ [user_at_host, "chmod", "+x", remote_path], :no_check},
      {:ssh_verify, ssh,
       base ++ port_arg(port, "-p") ++ [user_at_host, "[ -x #{remote_path} ] && echo ok"],
       :expect_ok}
    ]
  end

  @doc """
  Builds the single-step plan `install/3` runs for the in-memory content
  flow. The single `ssh` step writes the file, chmods it, and verifies it in
  one remote shell command; the file body arrives over stdin.

  Returns a one-element list shaped like `build_plan/8` entries so callers can
  introspect both flows uniformly.
  """
  @spec build_content_plan(
          String.t(),
          Path.t(),
          String.t() | nil,
          String.t() | nil,
          Path.t(),
          [String.t()]
        ) :: [{atom(), String.t(), [String.t()], :expect_ok}]
  def build_content_plan(user_at_host, remote_path, identity, port, ssh, ssh_opts) do
    base = identity_arg(identity) ++ ssh_opts
    quoted = shell_quote(remote_path)

    remote_cmd = "cat > #{quoted} && chmod +x #{quoted} && [ -x #{quoted} ] && echo ok"

    [
      {:ssh_pipe, ssh, base ++ port_arg(port, "-p") ++ [user_at_host, remote_cmd], :expect_ok}
    ]
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", ~s('"'"')) <> "'"

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

  defp run_content_plan([{_step, cmd, args, check}], content, timeout) do
    case ElixirExec.run([cmd | args], stdin: true) do
      {:ok, conn} ->
        with :ok <- write_stdin(conn, content) do
          collect_content_output(conn, [], check, timeout)
        end

      {:error, reason} ->
        {:error, "subprocess failed: #{inspect(reason)}"}
    end
  end

  # The script body is piped to ssh's stdin. A host that drops the connection
  # mid-write is an ordinary failure, so it is reported — these used to be
  # `:ok = ...` matches, which raised MatchError out of a function whose contract
  # is `{:error, String.t()}`.
  defp write_stdin(conn, content) do
    with :ok <- write_chunk(conn, content) do
      write_chunk(conn, :eof)
    end
  end

  defp write_chunk(conn, chunk) do
    case ElixirExec.write(conn, chunk) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write remote script to ssh: #{inspect(reason)}"}
    end
  end

  defp collect_content_output(conn, acc, check, timeout) do
    case ElixirExec.read(conn, timeout) do
      {:ok, {:stdout, data}} ->
        collect_content_output(conn, [acc, data], check, timeout)

      {:ok, {:stderr, data}} ->
        collect_content_output(conn, [acc, data], check, timeout)

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
