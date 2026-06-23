defmodule Mix.Tasks.Dockd.Package.Install do
  @moduledoc """
  Installs dockd packages from a remote source into the configured packages root.

  ## Usage

      mix dockd.package.install <source> --source=<url>

  Currently only `git` is supported as a source. The URL can be
  anything `git clone` accepts (HTTPS, SSH, or the
  `github.com/user/repo` shorthand). Every subdirectory under
  `<repo>/packages/` that contains a `package.json` is installed as
  `<packages_root>/<name>/`, overwriting any existing package with the
  same name.

  ## Examples

      mix dockd.package.install git --source=https://github.com/user/recipes
      mix dockd.package.install git --source=github.com/user/recipes
      mix dockd.package.install git --source=git@github.com:user/recipes.git
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
          Mix.raise("Missing required source argument (supported: git)")

        _ ->
          Mix.raise(
            "Unexpected positional arguments: #{Enum.join(args, " ")}. " <>
              "Usage: mix dockd.package.install <source> --source=<url>"
          )
      end

    url =
      opts[:source] ||
        Mix.raise("Missing required --source=<url> flag")

    Mix.Task.run("app.start")

    result =
      case source_type do
        "git" ->
          Dockd.Packages.install_from_git(url, [])

        other ->
          Mix.raise("Unsupported source #{inspect(other)} (supported: git)")
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
