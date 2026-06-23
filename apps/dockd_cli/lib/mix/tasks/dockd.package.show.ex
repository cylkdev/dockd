defmodule Mix.Tasks.Dockd.Package.Show do
  @moduledoc """
  Lists installed dockd packages.

  Scans the configured packages root for subdirectories containing a `package.json`
  and prints one row per package with name, image, and description.
  Packages whose `package.json` fails to parse are listed with
  `<invalid>` in the image column.

  ## Usage

      mix dockd.package.show

  ## Example output

      NAME           IMAGE             DESCRIPTION
      claude_code    debian:trixie     Anthropic Claude Code CLI ...
      smoke          busybox:1.37.0
  """
  @shortdoc "List installed dockd packages"

  use Mix.Task

  alias Dockd.Packages

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Packages.list() do
      [] ->
        Mix.shell().info("No installed packages.")

      packages ->
        print_table(packages)
    end
  end

  defp print_table(packages) do
    rows = Enum.map(packages, &row/1)
    headers = {"NAME", "IMAGE", "DESCRIPTION"}

    widths =
      [headers | rows]
      |> Enum.reduce({0, 0, 0}, fn {n, i, d}, {wn, wi, wd} ->
        {max(wn, String.length(n)), max(wi, String.length(i)), max(wd, String.length(d))}
      end)

    Mix.shell().info(format_row(headers, widths))
    for row <- rows, do: Mix.shell().info(format_row(row, widths))
  end

  defp row(%{name: name, spec: {:ok, spec}}) do
    {name, spec.image || "", spec.description || ""}
  end

  defp row(%{name: name, spec: {:error, %Dockd.Error{message: message}}}) do
    {name, "<invalid: #{message}>", ""}
  end

  defp format_row({n, i, d}, {wn, wi, _wd}) do
    [String.pad_trailing(n, wn), String.pad_trailing(i, wi), d] |> Enum.join("  ")
  end
end
