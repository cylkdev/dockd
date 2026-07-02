defmodule Mix.Tasks.Dockd.Package.Install do
  @moduledoc """
  Installs dockd packages from a remote source into the configured packages root.

  ## Usage

      mix dockd.package.install <source> --source=<url>

  Two source types are supported:

    - `git --source=<url>` clones a remote repo (HTTPS, SSH, or the
      `github.com/user/repo` shorthand) and installs every
      `<repo>/packages/<name>/` that contains a `package.json`.
    - `local --source=<dir>` installs every `<dir>/packages/<name>/`
      that contains a `package.json` from a local directory.

  Existing packages with the same name are overwritten.

  ## Examples

      mix dockd.package.install git --source=https://github.com/user/recipes
      mix dockd.package.install git --source=github.com/user/recipes
      mix dockd.package.install local --source=.
  """

  use Mix.Task

  @shortdoc "Install dockd packages from a remote source"

  @switches [source: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown flags: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    source_type =
      case args do
        [type] ->
          type

        [] ->
          Mix.raise("Missing required source argument (supported: git, local)")

        _ ->
          Mix.raise(
            "Unexpected positional arguments: #{Enum.join(args, " ")}. " <>
              "Usage: mix dockd.package.install <source> --source=<url>"
          )
      end

    url =
      case opts[:source] do
        nil -> Mix.raise("Missing required --source=<url> flag")
        "" -> Mix.raise("Missing required --source=<url> flag")
        source -> source
      end

    Mix.Task.run("app.start")

    result =
      case source_type do
        "git" ->
          Dockd.Packages.install_from_git(url, [])

        "local" ->
          Dockd.Packages.install_from_path(url, [])

        other ->
          Mix.raise("Unsupported source #{inspect(other)} (supported: git, local)")
      end

    case result do
      {:ok, []} ->
        Mix.shell().info("No packages found in repository's packages/ directory")

      {:ok, names} ->
        Mix.shell().info("Installed #{length(names)} package(s): #{Enum.join(names, ", ")}")

      {:error, %Dockd.Error{} = err} ->
        Mix.raise(Exception.message(err))
    end
  end
end
