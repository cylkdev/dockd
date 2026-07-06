defmodule Dockd.Tui.View.Output do
  @moduledoc """
  Accumulates and renders the feedback pane. `append/2` folds an action's text
  block into a line list (newest last, capped); `render/2` returns the trailing
  `height` lines for a `Paragraph`.
  """
  @max_lines 500

  @spec append([binary()], binary()) :: [binary()]
  def append(lines, text) do
    (lines ++ String.split(text, "\n"))
    |> Enum.take(-@max_lines)
  end

  @spec render([binary()], pos_integer()) :: binary()
  def render(lines, height) do
    lines
    |> Enum.take(-height)
    |> Enum.join("\n")
  end
end
