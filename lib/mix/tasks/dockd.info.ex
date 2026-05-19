defmodule Mix.Tasks.Dockd.Info do
  @moduledoc """
  Prints aggregate dockd state for the targeted node.

  Wraps `Dockd.info/1`. Shape is extension-friendly: each top-level key
  is rendered under its own header so future additions don't break the
  output format. Today the only key is `:temp_files`.

  ## Usage

      mix dockd.info
  """
  @shortdoc "Show aggregate dockd state"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Dockd.info() do
      {:ok, info} ->
        info |> Enum.sort() |> Enum.each(&render_section/1)

      {:error, %Dockd.Error{} = err} ->
        Mix.raise(Exception.message(err))

      {:error, reason} ->
        Mix.raise("Failed to fetch info: #{inspect(reason)}")
    end
  end

  defp render_section({key, value}) do
    Mix.shell().info("[#{key}]")

    case value do
      %{} = map ->
        for {k, v} <- Enum.sort(map) do
          Mix.shell().info("  #{k}: #{format_value(v)}")
        end

      other ->
        Mix.shell().info("  #{format_value(other)}")
    end

    Mix.shell().info("")
  end

  defp format_value(nil), do: "-"
  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
end
