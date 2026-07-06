defmodule Dockd.ShellTest do
  use ExUnit.Case, async: true
  alias Dockd.Instance

  describe "connect_command/2" do
    test "builds a docker exec -it command using the given program" do
      inst = %Instance{id: "1", name: "web", shell: "/bin/sh"}
      assert Dockd.Shell.connect_command(inst, "/bin/bash") == "docker exec -it web /bin/bash"
    end

    test "falls back to the instance shell then /bin/sh" do
      assert Dockd.Shell.connect_command(%Instance{name: "web", shell: "/bin/ash"}, nil) ==
               "docker exec -it web /bin/ash"

      assert Dockd.Shell.connect_command(%Instance{name: "web", shell: nil}, nil) ==
               "docker exec -it web /bin/sh"
    end

    test "shell-escapes a name with unsafe characters" do
      cmd = Dockd.Shell.connect_command(%Instance{name: "a b", shell: "/bin/sh"}, nil)
      assert cmd =~ "'a b'"
    end
  end

  describe "open_terminal/3" do
    test "returns :ok when the launcher exits 0" do
      launcher = write_launcher!("#!/bin/sh\nexit 0\n")
      assert Dockd.Shell.open_terminal(launcher, "docker exec -it web /bin/sh", "web") == :ok
    end

    test "returns {:error, _} when the launcher exits non-zero" do
      launcher = write_launcher!("#!/bin/sh\necho boom >&2\nexit 1\n")
      assert {:error, msg} = Dockd.Shell.open_terminal(launcher, "cmd", "web")
      assert msg =~ "boom"
    end

    test "returns {:error, _} when the launcher is missing" do
      assert {:error, msg} = Dockd.Shell.open_terminal("/no/such/launcher", "cmd", "web")
      assert is_binary(msg)
    end
  end

  describe "open_window/2" do
    test "uses an injected launcher path and reports success" do
      launcher = write_launcher!("#!/bin/sh\nexit 0\n")
      inst = %Instance{name: "web", shell: "/bin/sh"}
      assert Dockd.Shell.open_window(inst, launcher_path: launcher) == :ok
    end
  end

  defp write_launcher!(body) do
    path = Path.join(System.tmp_dir!(), "dockd-launcher-#{System.unique_integer([:positive])}")
    File.write!(path, body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
