defmodule Dockd.Tui.View.InstancesTest do
  use ExUnit.Case, async: true
  alias Dockd.Tui.View.Instances
  alias Dockd.Instance

  defp inst(name, running?),
    do: %Instance{id: "abcdef123456", name: name, image: "busybox:1.37.0", running?: running?}

  test "renders a header and one row per instance" do
    out = Instances.render([inst("web", true), inst("api", false)], 0)
    assert out =~ "NAME"
    assert out =~ "web"
    assert out =~ "api"
    assert out =~ "running"
    assert out =~ "stopped"
  end

  test "marks the selected row" do
    out = Instances.render([inst("web", true), inst("api", false)], 1)
    lines = String.split(out, "\n")
    assert Enum.any?(lines, &(String.starts_with?(&1, "> ") and &1 =~ "api"))
    assert Enum.any?(lines, &(String.starts_with?(&1, "  ") and &1 =~ "web"))
  end

  test "empty list renders a placeholder" do
    assert Instances.render([], 0) =~ "No dockd instances."
  end
end
