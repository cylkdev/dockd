defmodule Dockd.Tui.View.Commands do
  @moduledoc """
  Renders the command list panel to a multi-line string. Pure:
  `(commands, selection) -> text`. Selected row prefixed with `> `.
  """

  @spec render([map()], non_neg_integer()) :: binary()
  def render(commands, selection) do
    commands
    |> Enum.with_index()
    |> Enum.map(fn {cmd, index} ->
      prefix = if index == selection, do: "> ", else: "  "
      prefix <> cmd.label
    end)
    |> Enum.join("\n")
  end
end
