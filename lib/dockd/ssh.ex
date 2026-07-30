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
      body = DockerDialStdio.render_script(template, assigns)

      with :ok <- mkdir(dir),
           :ok <- write(target, body),
           :ok <- chmod(target) do
        {:ok, %{path: target, overwrote?: existed?}}
      end
    end
  end

  # A read-only target directory is an ordinary outcome here, not a bug, so it is
  # reported rather than raised — `generate_script/2` promises a tuple.
  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not create #{dir}: #{format(reason)}"}
    end
  end

  defp write(target, body) do
    case File.write(target, body) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write #{target}: #{format(reason)}"}
    end
  end

  defp chmod(target) do
    case File.chmod(target, 0o755) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not make #{target} executable: #{format(reason)}"}
    end
  end

  defp format(reason), do: reason |> :file.format_error() |> to_string()

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

end
