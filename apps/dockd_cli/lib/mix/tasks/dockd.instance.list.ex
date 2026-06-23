defmodule Mix.Tasks.Dockd.Instance.List do
  @moduledoc """
  Lists dockd-managed Docker containers.

  Calls `Dockd.list/1` and prints one row per instance with name, image,
  status, and short container ID. When no instances are running on the
  daemon, prints `No dockd instances.` and exits 0.

  ## Usage

      mix dockd.instance.list

  ## Example output

      NAME              IMAGE              STATUS    ID
      smoke             busybox:1.37.0     running   a1b2c3d4
      builder           debian:trixie      stopped   e5f6g7h8
  """
  @shortdoc "List dockd-managed instances"

  use Mix.Task

  alias Dockd.Instance

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Dockd.list() do
      {:ok, []} ->
        Mix.shell().info("No dockd instances.")

      {:ok, instances} ->
        print_table(instances)

      {:error, %Dockd.Error{} = err} ->
        Mix.raise(Exception.message(err))
    end
  end

  defp print_table(instances) do
    rows = Enum.map(instances, &row/1)
    headers = {"NAME", "IMAGE", "STATUS", "ID"}

    widths =
      [headers | rows]
      |> Enum.reduce({0, 0, 0, 0}, fn {n, i, s, id}, {wn, wi, ws, wid} ->
        {max(wn, String.length(n)), max(wi, String.length(i)), max(ws, String.length(s)),
         max(wid, String.length(id))}
      end)

    Mix.shell().info(format_row(headers, widths))
    for row <- rows, do: Mix.shell().info(format_row(row, widths))
  end

  defp row(%Instance{} = instance) do
    {
      Instance.short_name(instance),
      instance.image || "",
      if(instance.running?, do: "running", else: "stopped"),
      short_id(instance.id)
    }
  end

  defp short_id(nil), do: ""
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)

  defp format_row({n, i, s, id}, {wn, wi, ws, _wid}) do
    [
      String.pad_trailing(n, wn),
      String.pad_trailing(i, wi),
      String.pad_trailing(s, ws),
      id
    ]
    |> Enum.join("  ")
  end
end
