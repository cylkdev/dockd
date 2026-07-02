defmodule DockdCli.Commands.Package.Install do
  @moduledoc """
  Installs dockd packages from a remote source into the configured packages root.

  Wraps `Dockd.Packages.install_from_git/2`. Currently only `git` is
  supported as a source. The URL can be anything `git clone` accepts
  (HTTPS, SSH, or the `github.com/user/repo` shorthand). Every
  subdirectory under `<repo>/packages/` that contains a `package.json`
  is installed as `<packages_root>/<name>/`, overwriting any existing
  package with the same name.

  ## Args

  `args[:type]` — the source type (currently only `"git"`).
  `args[:source]` — the `--source=<url>` flag value.
  """

  alias Dockd.Packages
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(args, opts) do
    with {:ok, type} <- require_type(args),
         {:ok, source} <- require_source(args) do
      install(type, source, opts)
    end
  end

  defp require_type(args) do
    case Map.get(args, :type) do
      type when is_binary(type) and type != "" ->
        {:ok, type}

      _ ->
        {:error, "Missing required source argument (supported: git)"}
    end
  end

  defp require_source(args) do
    case Map.get(args, :source) do
      source when is_binary(source) and source != "" ->
        {:ok, source}

      _ ->
        {:error, "Missing required --source=<url> flag"}
    end
  end

  defp install("git", url, opts) do
    case Packages.install_from_git(url, opts) do
      {:ok, []} ->
        Output.info("No packages found in repository's packages/ directory")

      {:ok, names} ->
        Output.info("Installed #{length(names)} package(s): #{Enum.join(names, ", ")}")

      {:error, %Dockd.Error{} = err} ->
        {:error, Exception.message(err)}
    end
  end

  defp install(other, _url, _opts),
    do: {:error, "Unsupported source #{inspect(other)} (supported: git)"}
end
