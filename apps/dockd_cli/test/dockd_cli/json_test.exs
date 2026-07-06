defmodule DockdCLI.JsonTest do
  use ExUnit.Case, async: true
  alias DockdCLI.Json

  test "instance/1 maps a running instance to curated fields with the full id" do
    inst = %Dockd.Instance{
      name: "dockd-smoke",
      image: "busybox:1.37.0",
      running?: true,
      id: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    }

    assert Json.instance(inst) == %{
             name: "smoke",
             image: "busybox:1.37.0",
             status: "running",
             id: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
           }
  end

  test "instance/1 reports stopped instances" do
    inst = %Dockd.Instance{name: "dockd-x", image: nil, running?: false, id: nil}
    assert Json.instance(inst) == %{name: "x", image: nil, status: "stopped", id: nil}
  end

  test "action/2 builds an ok confirmation object" do
    assert Json.action("smoke", "destroyed") == %{
             name: "smoke",
             action: "destroyed",
             status: "ok"
           }
  end
end
