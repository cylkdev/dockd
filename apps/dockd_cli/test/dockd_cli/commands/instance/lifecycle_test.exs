defmodule DockdCLI.Commands.Instance.LifecycleTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias DockdCLI.Commands.Instance.{List, Stop, Start, Restart, Destroy}

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

  test "list render_json emits an empty array for no instances" do
    out = capture_io(fn -> assert List.render_json({:ok, []}) == :ok end)
    assert Jason.decode!(out) == []
  end

  test "list render_json emits one object per instance with the full id" do
    inst = [
      %Dockd.Instance{
        name: "dockd-smoke",
        image: "busybox:1.37.0",
        running?: true,
        id: "abcdef0123456789"
      }
    ]

    out = capture_io(fn -> List.render_json({:ok, inst}) end)

    assert Jason.decode!(out) == [
             %{
               "name" => "smoke",
               "image" => "busybox:1.37.0",
               "status" => "running",
               "id" => "abcdef0123456789"
             }
           ]
  end

  test "list render_json returns the Dockd.Error struct unchanged" do
    err = %Dockd.Error{phase: :discover, message: "boom"}
    assert List.render_json({:error, err}) == {:error, err}
  end

  test "start/restart run_json require a name" do
    assert {:error, _} = Start.run_json(%{}, [])
    assert {:error, _} = Restart.run_json(%{}, [])
  end

  test "stop run_json rejects --all with a name" do
    assert {:error, msg} = Stop.run_json(%{all: true, name: "smoke"}, [])
    assert msg =~ "--all"
  end

  test "stop run_json requires a name or --all" do
    assert {:error, _} = Stop.run_json(%{}, [])
  end

  test "destroy run_json requires a name" do
    assert {:error, _} = Destroy.run_json(%{}, [])
  end

  test "destroy run_json --all without --force errors instead of prompting" do
    assert {:error, msg} = Destroy.run_json(%{all: true}, [])
    assert msg =~ "--force"
  end
end
