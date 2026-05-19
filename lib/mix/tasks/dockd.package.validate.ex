defmodule Mix.Tasks.Dockd.Package.Validate do
  @moduledoc """
  Validates installed dockd packages by running the full spec-loading
  pipeline against each `package.json`.

  Runs every step a real `mix dockd.instance.run --preset NAME` would
  run: read the file, parse the JSON, substitute `${VAR}` references
  against the host environment, and normalize attributes. Reports each
  package as `OK` or `FAIL: <phase> — <message>` and exits non-zero if
  anything fails.

  ## Usage

      mix dockd.package.validate          # validate every installed package
      mix dockd.package.validate <name>   # validate one package by name or path
  """
  @shortdoc "Validate installed dockd packages"

  use Mix.Task

  alias Dockd.Error
  alias Dockd.Packages
  alias Dockd.Spec
  alias Dockd.Spec.Interpolator
  alias Dockd.Spec.Normalizer
  alias Dockd.Spec.Parser
  alias Dockd.Spec.Source

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [] -> validate_all()
      [ref] -> validate_one(ref)
      _ -> Mix.raise("Usage: mix dockd.package.validate [<name>]")
    end
  end

  defp validate_all do
    case Packages.list() do
      [] ->
        Mix.shell().info("No installed packages.")

      packages ->
        results = Enum.map(packages, &validate_package/1)
        Enum.each(results, &print_result/1)
        if Enum.any?(results, &match?({_, {:error, _}}, &1)), do: exit_failure()
    end
  end

  defp validate_one(ref) do
    path = Packages.resolve_path(ref)
    name = ref |> Path.basename() |> Path.rootname(".json")
    result = {name, validate_path(path)}
    print_result(result)
    if match?({_, {:error, _}}, result), do: exit_failure()
  end

  defp validate_package(%{name: name, path: path}) do
    {name, validate_path(Path.join(path, "package.json"))}
  end

  defp validate_path(json_path) do
    with {:ok, body} <- Source.read_file(json_path),
         {:ok, decoded} <- Parser.parse(body),
         {:ok, substituted} <- Interpolator.substitute(decoded, System.get_env()),
         {:ok, attrs} <- Normalizer.normalize(substituted, Path.dirname(json_path)) do
      {:ok, Spec.from_attrs(attrs)}
    end
  end

  defp print_result({name, {:ok, _spec}}) do
    Mix.shell().info("#{name}  OK")
  end

  defp print_result({name, {:error, %Error{phase: phase, message: message}}}) do
    Mix.shell().info("#{name}  FAIL: #{phase} — #{message}")
  end

  defp exit_failure do
    Mix.raise("one or more packages failed validation")
  end
end
