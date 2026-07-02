defmodule DockdCli.Commands.Info do
  @moduledoc "Prints aggregate dockd state, one section per top-level key."
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(_args, opts), do: render(Dockd.info(opts))

  @doc false
  def render({:ok, info}) do
    info |> Enum.sort() |> Enum.each(&render_section/1)
    :ok
  end

  def render({:error, %Dockd.Error{} = err}), do: {:error, Exception.message(err)}
  def render({:error, reason}), do: {:error, "Failed to fetch info: #{inspect(reason)}"}

  defp render_section({key, value}) do
    Output.info("[#{key}]")

    case value do
      %{} = map -> for {k, v} <- Enum.sort(map), do: Output.info("  #{k}: #{format_value(v)}")
      other -> Output.info("  #{format_value(other)}")
    end

    Output.info("")
  end

  defp format_value(nil), do: "-"
  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
end
