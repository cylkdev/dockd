defmodule DockdCli.Output do
  @moduledoc "Mix-free output helpers for the standalone CLI."

  @spec info(iodata()) :: :ok
  def info(msg), do: IO.puts(msg)

  @spec error(iodata()) :: :ok
  def error(msg), do: IO.puts(:stderr, msg)

  @spec write(iodata()) :: :ok
  def write(bytes), do: IO.write(bytes)

  @spec table([tuple()], tuple()) :: :ok
  def table(rows, header) when is_tuple(header) do
    widths = column_widths([header | rows])
    info(format_row(header, widths))
    Enum.each(rows, &info(format_row(&1, widths)))
  end

  defp column_widths(rows) do
    arity = tuple_size(hd(rows))

    for col <- 0..(arity - 1) do
      rows |> Enum.map(&(&1 |> elem(col) |> to_string() |> String.length())) |> Enum.max()
    end
  end

  defp format_row(row, widths) do
    cols = Tuple.to_list(row)
    last = length(cols) - 1

    cols
    |> Enum.with_index()
    |> Enum.map_join("  ", fn {value, idx} ->
      str = to_string(value)
      if idx == last, do: str, else: String.pad_trailing(str, Enum.at(widths, idx))
    end)
  end
end
