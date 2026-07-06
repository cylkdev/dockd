defmodule Dockd.Ssh do
  @moduledoc """
  Shared, frontend-agnostic entry points for the dial-stdio bridge script.

  Both the CLI (`dockd ssh dial_stdio_script ...`) and the TUI call these
  functions, so the filesystem/source-resolution glue lives here once rather
  than in a frontend adapter. The wire-level work stays in
  `Dockd.Ssh.DockerDialStdio`.
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
    target = Path.join(dir, @filename)
    existed? = File.exists?(target)

    if existed? and not force? do
      {:error,
       "#{target} already exists. Re-run with force to overwrite, " <>
         "or choose another directory."}
    else
      File.mkdir_p!(dir)
      File.write!(target, DockerDialStdio.render_script([]))
      File.chmod!(target, 0o755)
      {:ok, %{path: target, overwrote?: existed?}}
    end
  end

  @doc """
  Resolves an install source. Explicit `path` is used verbatim (must exist);
  `nil` prefers `./#{@filename}` in the cwd, else the in-memory bundled
  template (`:default`). Returns `{:ok, {source, description}}`.
  """
  @spec resolve_source(binary() | nil) ::
          {:ok, {binary() | :default, binary()}} | {:error, binary()}
  def resolve_source(nil) do
    cwd_path = Path.join(File.cwd!(), @filename)

    if File.exists?(cwd_path),
      do: {:ok, {cwd_path, "./#{@filename}"}},
      else: {:ok, {:default, "bundled template (in-memory)"}}
  end

  def resolve_source(path) when is_binary(path) do
    if File.exists?(path),
      do: {:ok, {path, path}},
      else: {:error, "script path #{path} does not exist"}
  end

  @doc """
  Deploys a resolved `source` to `user_at_host`. Forwards `:remote_path`,
  `:identity`, `:port` to `Dockd.Ssh.DockerDialStdio.install/3`.
  """
  @spec install_script(binary() | :default, binary(), keyword()) ::
          {:ok, %{remote_path: binary()}} | {:error, term()}
  def install_script(source, user_at_host, opts \\ []) do
    DockerDialStdio.install(source, user_at_host, opts)
  end
end
