defmodule DockdCli.Commands.Package.Validate do
  @moduledoc """
  Validates installed dockd packages by running the full spec-loading
  pipeline against each `package.json`.

  Runs every step a real `dockd instance run --preset NAME` would run:
  read the file, parse the JSON, substitute `${VAR}` references against
  the host environment, and normalize attributes. Reports each package
  as `OK` or `FAIL: <phase> — <message>` and returns `{:error, _}` if
  anything fails.

  ## Args

  `args[:name]` — optional package name or path. When absent, every
  installed package is validated.
  """

  alias Dockd.Error
  alias Dockd.Packages
  alias Dockd.Spec
  alias Dockd.Spec.Interpolator
  alias Dockd.Spec.Normalizer
  alias Dockd.Spec.Parser
  alias Dockd.Spec.Source
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(args, opts) do
    case Map.get(args, :name) do
      ref when is_binary(ref) and ref != "" -> validate_one(ref, opts)
      _ -> validate_all(opts)
    end
  end

  defp validate_all(opts) do
    case Packages.list(opts) do
      [] ->
        Output.info("No installed packages.")
        :ok

      packages ->
        results = Enum.map(packages, &validate_package(&1, opts))
        Enum.each(results, &print_result/1)
        if Enum.any?(results, &match?({_, {:error, _}}, &1)), do: exit_failure(), else: :ok
    end
  end

  defp validate_one(ref, opts) do
    path = Packages.resolve_path(ref, opts)
    name = ref |> Path.basename() |> Path.rootname(".json")
    result = {name, validate_path(path)}
    print_result(result)
    if match?({_, {:error, _}}, result), do: exit_failure(), else: :ok
  end

  defp validate_package(%{name: name, path: path}, _opts) do
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
    Output.info("#{name}  OK")
  end

  defp print_result({name, {:error, %Error{phase: phase, message: message}}}) do
    Output.info("#{name}  FAIL: #{phase} — #{message}")
  end

  defp exit_failure, do: {:error, "one or more packages failed validation"}
end
