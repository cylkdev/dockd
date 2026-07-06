defmodule Mix.Tasks.DockdForwarderTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  test "mix dockd --version forwards to CLI and prints version" do
    out = capture_io(fn -> assert Mix.Tasks.Dockd.run(["--version"]) == :ok end)
    assert out =~ "dockd"
  end

  test "mix dockd with no args prints help" do
    out = capture_io(fn -> Mix.Tasks.Dockd.run([]) end)
    assert out =~ "dockd"
  end
end
