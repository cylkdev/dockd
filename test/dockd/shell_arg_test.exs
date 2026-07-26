defmodule Dockd.ShellArgTest do
  use ExUnit.Case, async: true

  describe "resolve_shell_arg/2" do
    test "defaults to configured shell wrapped as argv" do
      assert Dockd.resolve_shell_arg([], "claude") === [shell: ["claude"]]
    end

    test "explicit :shell opt wins and is not re-wrapped" do
      assert Dockd.resolve_shell_arg([shell: ["bash", "-l"]], "claude") === []
    end

    test "no configured shell injects nothing" do
      assert Dockd.resolve_shell_arg([], nil) === []
    end
  end
end
