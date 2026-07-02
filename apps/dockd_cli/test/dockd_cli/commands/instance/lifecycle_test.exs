defmodule DockdCli.Commands.Instance.LifecycleTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias DockdCli.Commands.Instance.{List, Stop, Start, Restart, Destroy}

  test "list prints message when empty" do
    assert capture_io(fn -> assert List.render({:ok, []}) == :ok end) == "No dockd instances.\n"
  end

  test "list prints a table row" do
    inst = [
      %Dockd.Instance{
        name: "dockd-smoke",
        image: "busybox:1.37.0",
        running?: true,
        id: "abcdef0123456789"
      }
    ]

    out = capture_io(fn -> List.render({:ok, inst}) end)
    assert out =~ "NAME" and out =~ "smoke" and out =~ "running" and out =~ "abcdef012345"
  end

  test "stop rejects --all with a name" do
    assert {:error, msg} = Stop.run(%{all: true, name: "smoke"}, [])
    assert msg =~ "--all"
  end

  test "start/restart/destroy require a name" do
    assert {:error, _} = Start.run(%{}, [])
    assert {:error, _} = Restart.run(%{}, [])
    assert {:error, _} = Destroy.run(%{}, [])
  end
end
