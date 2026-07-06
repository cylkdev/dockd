defmodule DockdCLI.Commands.Ssh.DialStdioScript.GenerateTest do
  use ExUnit.Case
  alias DockdCLI.Commands.Ssh.DialStdioScript.Generate

  setup do
    tmp = Path.join(System.tmp_dir!(), "dockd-gen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp_dir: tmp}
  end

  test "writes an executable script into output_dir", %{tmp_dir: tmp} do
    assert Generate.run(%{output_dir: tmp}, []) == :ok
    target = Path.join(tmp, "docker_dial_stdio_script.sh")
    assert File.exists?(target)
    assert String.starts_with?(File.read!(target), "#!/bin/sh")
    %File.Stat{mode: mode} = File.stat!(target)
    assert Bitwise.band(mode, 0o100) == 0o100
  end

  test "refuses to overwrite without force, returns {:error, msg}", %{tmp_dir: tmp} do
    target = Path.join(tmp, "docker_dial_stdio_script.sh")
    File.write!(target, "old")
    assert {:error, msg} = Generate.run(%{output_dir: tmp}, [])
    assert msg =~ "already exists"
    assert File.read!(target) == "old"
  end

  test "force overwrites", %{tmp_dir: tmp} do
    target = Path.join(tmp, "docker_dial_stdio_script.sh")
    File.write!(target, "old")
    assert Generate.run(%{output_dir: tmp, force: true}, []) == :ok
    assert String.starts_with?(File.read!(target), "#!/bin/sh")
  end
end
