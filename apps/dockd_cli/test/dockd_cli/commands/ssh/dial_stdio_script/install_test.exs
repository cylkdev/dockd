defmodule DockdCLI.Commands.Ssh.DialStdioScript.InstallTest do
  use ExUnit.Case

  alias DockdCLI.Commands.Ssh.DialStdioScript.Install

  describe "args parsing" do
    test "missing user_at_host returns {:error, msg} with usage hint" do
      assert {:error, msg} = Install.run(%{}, [])
      assert msg =~ ~r/USER_AT_HOST/
    end

    test "script_path that does not exist returns {:error, msg}" do
      missing = Path.join(System.tmp_dir!(), "definitely-not-here-#{:rand.uniform(1_000_000)}.sh")

      assert {:error, msg} =
               Install.run(%{user_at_host: "user@host", script_path: missing}, [])

      assert msg =~ ~r/does not exist/
    end
  end
end
