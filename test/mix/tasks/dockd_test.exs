defmodule Mix.Tasks.DockdTest do
  use ExUnit.Case

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  describe "run/1" do
    test "prints usage with every subtask listed" do
      Mix.Tasks.Dockd.run([])

      assert_received {:mix_shell, :info, ["Usage: mix dockd.<task> [args]"]}
      assert_received {:mix_shell, :info, ["Available tasks:"]}

      messages = drain_info_messages()
      joined = Enum.join(messages, "\n")

      for invocation <- [
            "mix dockd.instance.run",
            "mix dockd.instance.list",
            "mix dockd.instance.start",
            "mix dockd.instance.stop",
            "mix dockd.instance.restart",
            "mix dockd.instance.destroy",
            "mix dockd.instance.logs",
            "mix dockd.instance.inspect",
            "mix dockd.info",
            "mix dockd.package.install",
            "mix dockd.package.show"
          ] do
        assert joined =~ invocation, "expected usage to mention `#{invocation}`"
      end

      assert joined =~ "mix help dockd."
    end

    test "ignores positional arguments" do
      Mix.Tasks.Dockd.run(["something", "--flag"])

      assert_received {:mix_shell, :info, ["Usage: mix dockd.<task> [args]"]}
    end
  end

  defp drain_info_messages(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> drain_info_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
