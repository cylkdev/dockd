defmodule Dockd.SshTest do
  use ExUnit.Case, async: true

  setup do
    tmp = Path.join(System.tmp_dir!(), "dockd-ssh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "generate_script/2" do
    test "writes an executable script and reports the path", %{tmp: tmp} do
      assert {:ok, %{path: path, overwrote?: false}} = Dockd.Ssh.generate_script(tmp, [])
      assert path == Path.join(tmp, "docker_dial_stdio_script.sh")
      assert String.starts_with?(File.read!(path), "#!/bin/sh")
      %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o100) == 0o100
    end

    test "refuses to overwrite without force", %{tmp: tmp} do
      path = Path.join(tmp, "docker_dial_stdio_script.sh")
      File.write!(path, "old")
      assert {:error, msg} = Dockd.Ssh.generate_script(tmp, [])
      assert msg =~ "already exists"
      assert File.read!(path) == "old"
    end

    test "force overwrites and flags overwrote?", %{tmp: tmp} do
      path = Path.join(tmp, "docker_dial_stdio_script.sh")
      File.write!(path, "old")
      assert {:ok, %{overwrote?: true}} = Dockd.Ssh.generate_script(tmp, force: true)
      assert String.starts_with?(File.read!(path), "#!/bin/sh")
    end
  end

  describe "resolve_source/1" do
    test "nil with no cwd file resolves to the bundled template", %{tmp: tmp} do
      File.cd!(tmp, fn ->
        assert {:ok, {:default, desc}} = Dockd.Ssh.resolve_source(nil)
        assert desc =~ "bundled"
      end)
    end

    test "explicit existing path is used verbatim", %{tmp: tmp} do
      path = Path.join(tmp, "my_script.sh")
      File.write!(path, "#!/bin/sh\n")
      assert {:ok, {^path, ^path}} = Dockd.Ssh.resolve_source(path)
    end

    test "explicit missing path errors" do
      assert {:error, msg} = Dockd.Ssh.resolve_source("/no/such/file.sh")
      assert msg =~ "does not exist"
    end
  end
end
