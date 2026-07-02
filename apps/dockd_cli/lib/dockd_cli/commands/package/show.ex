defmodule DockdCli.Commands.Package.Show do
  @moduledoc """
  Lists installed dockd packages.

  Wraps `Dockd.Packages.list/1`. Scans the configured packages root for
  subdirectories containing a `package.json` and prints one row per
  package with name, image, and description. Packages whose
  `package.json` fails to parse are listed with `<invalid: ...>` in the
  image column.

  Takes no required arguments.
  """

  alias Dockd.Packages
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(_args, opts) do
    case Packages.list(opts) do
      [] ->
        Output.info("No installed packages.")

      packages ->
        print_table(packages)
    end

    :ok
  end

  defp print_table(packages) do
    rows = Enum.map(packages, &row/1)
    Output.table(rows, {"NAME", "IMAGE", "DESCRIPTION"})
  end

  defp row(%{name: name, spec: {:ok, spec}}) do
    {name, spec.image || "", spec.description || ""}
  end

  defp row(%{name: name, spec: {:error, %Dockd.Error{message: message}}}) do
    {name, "<invalid: #{message}>", ""}
  end
end
