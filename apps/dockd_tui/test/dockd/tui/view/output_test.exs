defmodule Dockd.Tui.View.OutputTest do
  use ExUnit.Case, async: true
  alias Dockd.Tui.View.Output

  test "append splits on newlines and keeps order" do
    lines = [] |> Output.append("a\nb") |> Output.append("c")
    assert lines == ["a", "b", "c"]
  end

  test "render shows only the trailing `height` lines" do
    lines = Enum.map(1..10, &Integer.to_string/1)
    assert Output.render(lines, 3) == "8\n9\n10"
  end

  test "append caps history at 500 lines" do
    big = Enum.reduce(1..600, [], fn n, acc -> Output.append(acc, Integer.to_string(n)) end)
    assert length(big) == 500
    assert List.last(big) == "600"
  end
end
