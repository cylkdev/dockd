defmodule Mix.Tasks.DockdClaudeCodeInstallTest do
  use ExUnit.Case

  alias Dockd.ClaudeCode.Packages

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    :ok
  end

  test "generates packages into --packages-path" do
    root = sandbox_dir("dockd-claude-code-task")

    Mix.Tasks.Dockd.ClaudeCode.Install.run(["--packages-path", root])

    for name <- Packages.package_names() do
      assert File.exists?(Path.join([root, name, "package.json"]))
      assert File.exists?(Path.join([root, name, "Dockerfile"]))
    end

    messages = drain_info_messages()
    assert length(messages) === length(Packages.package_names())
  end

  test "passes --force to the generator" do
    root = sandbox_dir("dockd-claude-code-task-force")
    stale = Path.join([root, "claude_code", "stale.txt"])
    File.mkdir_p!(Path.dirname(stale))
    File.write!(stale, "stale")

    Mix.Tasks.Dockd.ClaudeCode.Install.run(["--packages-path", root, "--force"])

    refute File.exists?(stale)
    assert File.exists?(Path.join([root, "claude_code", "package.json"]))
  end

  defp drain_info_messages(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> drain_info_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sandbox_dir(prefix) do
    dir =
      Path.join([
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
