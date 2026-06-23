defmodule Mix.Tasks.DockdTuiTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  test "prints help through the CLI module" do
    output =
      capture_io(fn ->
        Mix.Tasks.Dockd.Tui.run(["--help"])
      end)

    assert output =~ "Usage: dockd_tui INSTANCE"
  end
end
