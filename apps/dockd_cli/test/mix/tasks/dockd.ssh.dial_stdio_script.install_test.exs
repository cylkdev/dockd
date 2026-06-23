defmodule Mix.Tasks.Dockd.Ssh.DialStdioScript.InstallTest do
  use ExUnit.Case

  alias Mix.Tasks.Dockd.Ssh.DialStdioScript.Install

  describe "argv parsing" do
    test "missing USER_AT_HOST argument raises Mix error with usage hint" do
      assert_raise Mix.Error, ~r/USER_AT_HOST/, fn ->
        Install.run([])
      end
    end

    test "--script-path that does not exist raises Mix error" do
      missing = Path.join(System.tmp_dir!(), "definitely-not-here-#{:rand.uniform(1_000_000)}.sh")

      assert_raise Mix.Error, ~r/does not exist/, fn ->
        Install.run(["user@host", "--script-path", missing])
      end
    end
  end
end
