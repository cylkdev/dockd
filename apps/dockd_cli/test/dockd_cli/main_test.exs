defmodule DockdCli.MainTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  test "bare invocation prints help and succeeds" do
    out = capture_io(fn -> assert DockdCli.Main.run([]) == :ok end)
    assert out =~ "dockd"
  end

  test "parent subcommand with no leaf child prints help and does not crash" do
    out = capture_io(fn -> assert DockdCli.Main.run(["instance"]) == :ok end)
    assert out =~ "dockd"
  end

  test "unknown command returns error and writes to stderr" do
    err = capture_io(:stderr, fn -> send(self(), {:r, DockdCli.Main.run(["bogus-cmd"])}) end)
    assert_received {:r, {:error, _}}
    assert err != ""
  end
end
