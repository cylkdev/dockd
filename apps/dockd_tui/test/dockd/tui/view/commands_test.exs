defmodule Dockd.Tui.View.CommandsTest do
  use ExUnit.Case, async: true
  alias Dockd.Tui.Commands

  test "renders each command label with the selection marked" do
    out = Dockd.Tui.View.Commands.render(Commands.all(), 0)
    assert out =~ "instance run"
    assert out =~ "package install"
    first = out |> String.split("\n") |> List.first()
    assert String.starts_with?(first, "> ")
  end
end
