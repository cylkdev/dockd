defmodule Dockd.Tui.View.Instances do
  @moduledoc """
  Renders the instance list panel to a multi-line string (drawn in a
  `Paragraph`). Pure: `(instances, selection) -> text`. The selected row is
  prefixed with `> `.
  """
  alias Dockd.Instance

  @header "  NAME            IMAGE                STATUS   ID"

  @spec render([Instance.t()], non_neg_integer()) :: binary()
  def render([], _selection), do: @header <> "\n  No dockd instances."

  def render(instances, selection) do
    rows =
      instances
      |> Enum.with_index()
      |> Enum.map(fn {instance, index} -> row(instance, index == selection) end)

    Enum.join([@header | rows], "\n")
  end

  defp row(%Instance{} = instance, selected?) do
    prefix = if selected?, do: "> ", else: "  "
    name = Instance.short_name(instance) |> pad(15)
    image = (instance.image || "") |> pad(20)
    status = if(instance.running?, do: "running", else: "stopped") |> pad(8)
    prefix <> name <> " " <> image <> " " <> status <> " " <> short_id(instance.id)
  end

  defp pad(s, n), do: String.pad_trailing(String.slice(s, 0, n), n)
  defp short_id(nil), do: ""
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)
end
