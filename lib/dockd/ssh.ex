defmodule Dockd.Ssh do
  @moduledoc """
  Entry points for the dial-stdio bridge script, used when talking to a Docker
  daemon on a remote host over SSH.

  The filesystem and source-resolution glue lives here — rendering the bundled
  template to disk and deciding which script source to use — so callers do not
  have to repeat it. The wire-level work stays in `Dockd.Ssh.DockerDialStdio`.
  """
  alias Dockd.Ssh.DockerDialStdio

  @filename "docker_dial_stdio_script.sh"

  @doc """
  Renders the bundled dial-stdio script into `dir` as an executable file.

  Returns `{:ok, %{path: path, overwrote?: bool}}` or `{:error, message}` when
  the target exists and `:force` is not set.
  """
  @spec generate_script(Path.t(), keyword()) ::
          {:ok, %{path: Path.t(), overwrote?: boolean()}} | {:error, binary()}
  def generate_script(dir, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    target = Path.join(dir, Keyword.get(opts, :filename, @filename))
    existed? = File.exists?(target)

    if existed? and not force? do
      {:error,
       "#{target} already exists. Re-run with force to overwrite, " <>
         "or choose another directory."}
    else
      template = Keyword.get(opts, :template_path, DockerDialStdio.default_template_path())
      assigns = Keyword.get(opts, :assigns, [])

      File.mkdir_p!(dir)
      File.write!(target, DockerDialStdio.render_script(template, assigns))
      File.chmod!(target, 0o755)
      {:ok, %{path: target, overwrote?: existed?}}
    end
  end

  @doc """
  Resolves an install source.

  Either `:default` — the in-memory bundled template — or an absolute `path` that
  must exist. Returns `{:ok, {source, description}}`.

  There is deliberately no clause that searches for a script: an earlier version
  accepted `nil` and preferred `./#{@filename}` from the current working
  directory, which meant the same call installed a different script depending on
  where the caller happened to run it. A relative `path` is rejected for the same
  reason — `File.exists?/1` would resolve it against the CWD.
  """
  @spec resolve_source(binary() | :default) ::
          {:ok, {binary() | :default, binary()}} | {:error, binary()}
  def resolve_source(:default), do: {:ok, {:default, "bundled template (in-memory)"}}

  def resolve_source(path) when is_binary(path) do
    cond do
      Path.type(path) !== :absolute ->
        {:error, "script path #{path} must be absolute"}

      not File.exists?(path) ->
        {:error, "script path #{path} does not exist"}

      true ->
        {:ok, {path, path}}
    end
  end

  @doc """
  Deploys a resolved `source` to `user_at_host` using the given `ssh` and `scp`
  executables.

  `ssh_path` and `scp_path` are required so the connection cannot depend on
  whichever binaries happen to be on `PATH`. Forwards `:remote_path`,
  `:identity`, `:port`, `:ssh_opts`, and `:timeout` to
  `Dockd.Ssh.DockerDialStdio.install/5`.
  """
  @spec install_script(binary() | :default, binary(), Path.t(), Path.t(), keyword()) ::
          {:ok, %{remote_path: binary()}} | {:error, term()}
  def install_script(source, user_at_host, ssh_path, scp_path, opts \\ []) do
    DockerDialStdio.install(source, user_at_host, ssh_path, scp_path, opts)
  end
end
