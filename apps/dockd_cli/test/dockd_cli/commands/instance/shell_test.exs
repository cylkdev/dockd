defmodule DockdCLI.Commands.Instance.ShellTest do
  use ExUnit.Case, async: true
  alias DockdCLI.Commands.Instance.Shell

  describe "ensure_running/1" do
    test "ok when running" do
      assert :ok = Shell.ensure_running(%Dockd.Instance{name: "x", running?: true})
    end

    test "error when not running" do
      assert {:error, msg} = Shell.ensure_running(%Dockd.Instance{name: "x", running?: false})
      assert msg =~ "not running"
    end
  end

  describe "run/2 with no name" do
    test "returns a usage error pointing at instance list (no Docker call)" do
      assert {:error, msg} = Shell.run(%{}, [])
      assert msg =~ "Usage"
      assert msg =~ "list"
    end
  end

  describe "shell spec flags" do
    test "the shell subcommand exposes --name, --shell and --print" do
      {:ok, [:instance, :shell], parsed} =
        Optimus.parse(DockdCLI.CLI.spec(), [
          "instance",
          "shell",
          "--name",
          "web",
          "--print"
        ])

      assert parsed.options.name == "web"
      assert parsed.flags.print == true
    end
  end
end
