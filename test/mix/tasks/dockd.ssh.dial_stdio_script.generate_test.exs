defmodule Mix.Tasks.Dockd.Ssh.DialStdioScript.GenerateTest do
  use ExUnit.Case

  alias Mix.Tasks.Dockd.Ssh.DialStdioScript.Generate

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "dockd-generate-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp_dir: tmp}
  end

  describe "run/1" do
    test "writes docker_dial_stdio_script.sh into --output-dir as executable", %{tmp_dir: tmp} do
      Generate.run(["--output-dir", tmp])

      target = Path.join(tmp, "docker_dial_stdio_script.sh")
      assert File.exists?(target)
      assert String.starts_with?(File.read!(target), "#!/bin/sh")

      %File.Stat{mode: mode} = File.stat!(target)
      # the executable bit for owner must be set
      assert Bitwise.band(mode, 0o100) === 0o100
    end

    test "refuses to overwrite an existing file without --force", %{tmp_dir: tmp} do
      target = Path.join(tmp, "docker_dial_stdio_script.sh")
      File.write!(target, "preexisting content")

      assert_raise Mix.Error, ~r/already exists/, fn ->
        Generate.run(["--output-dir", tmp])
      end

      assert File.read!(target) === "preexisting content"
    end

    test "overwrites an existing file with --force", %{tmp_dir: tmp} do
      target = Path.join(tmp, "docker_dial_stdio_script.sh")
      File.write!(target, "preexisting content")

      Generate.run(["--output-dir", tmp, "--force"])

      assert String.starts_with?(File.read!(target), "#!/bin/sh")
    end

    test "creates --output-dir if it does not exist", %{tmp_dir: tmp} do
      nested = Path.join(tmp, "nested/sub")

      Generate.run(["--output-dir", nested])

      assert File.exists?(Path.join(nested, "docker_dial_stdio_script.sh"))
    end

    test "defaults --output-dir to cwd", %{tmp_dir: tmp} do
      cwd = File.cwd!()

      try do
        File.cd!(tmp)
        Generate.run([])
        assert File.exists?(Path.join(tmp, "docker_dial_stdio_script.sh"))
      after
        File.cd!(cwd)
      end
    end
  end
end
