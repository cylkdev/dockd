defmodule DockdCLI.MainTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "bare invocation prints help and succeeds" do
    out = capture_io(fn -> assert DockdCLI.CLI.run([]) == :ok end)
    assert out =~ "dockd"
  end

  test "parent subcommand with no leaf child prints help and does not crash" do
    out = capture_io(fn -> assert DockdCLI.CLI.run(["instance"]) == :ok end)
    assert out =~ "dockd"
  end

  test "unknown command returns error and writes to stderr" do
    err = capture_io(:stderr, fn -> send(self(), {:r, DockdCLI.CLI.run(["bogus-cmd"])}) end)
    assert_received {:r, {:error, _}}
    assert err != ""
  end

  test "--json usage error is emitted as JSON on stderr" do
    err =
      capture_io(:stderr, fn ->
        send(self(), {:r, DockdCLI.CLI.run(["instance", "stop", "--json"])})
      end)

    assert_received {:r, {:error, _}}
    assert %{"error" => %{"message" => msg}} = Jason.decode!(err)
    assert msg =~ "Usage"
  end
end
