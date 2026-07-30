defmodule Dockd.ShellTest do
  # Not async: one test sets $TERMINAL to prove an inherited value cannot win.
  use ExUnit.Case, async: false
  alias Dockd.Instance

  @docker "/usr/local/bin/docker"
  @endpoint "unix:///var/run/docker.sock"

  describe "connect_command/4" do
    test "builds a docker exec -it command using the given program" do
      inst = %Instance{id: "1", name: "web", shell: "/bin/sh"}

      assert Dockd.Shell.connect_command(inst, "/bin/bash", @docker, @endpoint) ==
               "DOCKER_HOST=#{@endpoint} #{@docker} exec -it web /bin/bash"
    end

    test "falls back to the instance shell then /bin/sh" do
      assert Dockd.Shell.connect_command(
               %Instance{name: "web", shell: "/bin/ash"},
               nil,
               @docker,
               @endpoint
             ) =~ "exec -it web /bin/ash"

      assert Dockd.Shell.connect_command(
               %Instance{name: "web", shell: nil},
               nil,
               @docker,
               @endpoint
             ) =~ "exec -it web /bin/sh"
    end

    test "shell-escapes a name with unsafe characters" do
      cmd =
        Dockd.Shell.connect_command(
          %Instance{name: "a b", shell: "/bin/sh"},
          nil,
          @docker,
          @endpoint
        )

      assert cmd =~ "'a b'"
    end

    # Without this the new window would run whichever docker its own PATH found,
    # against whichever daemon that CLI's DOCKER_HOST pointed at — so a shell into
    # a remote instance would silently target the local daemon.
    test "targets the daemon it was given, not the window's own environment" do
      cmd =
        Dockd.Shell.connect_command(
          %Instance{name: "web", shell: "/bin/sh"},
          nil,
          "/opt/bin/docker",
          "tcp://10.0.0.1:2376"
        )

      assert cmd =~ "DOCKER_HOST=tcp://10.0.0.1:2376"
      assert cmd =~ "/opt/bin/docker exec"
    end

    test "shell-escapes an endpoint and docker path with unsafe characters" do
      cmd =
        Dockd.Shell.connect_command(
          %Instance{name: "web", shell: "/bin/sh"},
          nil,
          "/opt/my docker",
          "tcp://h;rm -rf /"
        )

      assert cmd =~ "'/opt/my docker'"
      assert cmd =~ "'tcp://h;rm -rf /'"
    end
  end

  describe "open_terminal/3" do
    test "returns :ok when the launcher exits 0" do
      launcher = write_launcher!("#!/bin/sh\nexit 0\n")
      assert Dockd.Shell.open_terminal(launcher, "docker exec -it web /bin/sh", "xterm") == :ok
    end

    test "returns {:error, _} when the launcher exits non-zero" do
      launcher = write_launcher!("#!/bin/sh\necho boom >&2\nexit 1\n")
      assert {:error, msg} = Dockd.Shell.open_terminal(launcher, "cmd", "xterm")
      assert msg =~ "boom"
    end

    test "returns {:error, _} when the launcher is missing" do
      assert {:error, msg} = Dockd.Shell.open_terminal("/no/such/launcher", "cmd", "xterm")
      assert is_binary(msg)
    end

    # $TERMINAL decides which emulator opens and whether this call blocks for the
    # shell's lifetime, so it is set explicitly rather than inherited.
    test "passes the given terminal as $TERMINAL instead of inheriting it" do
      out = Path.join(System.tmp_dir!(), "dockd-term-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(out) end)

      launcher = write_launcher!("#!/bin/sh\nprintf '%s' \"$TERMINAL\" > #{out}\n")

      previous = System.get_env("TERMINAL")
      System.put_env("TERMINAL", "inherited-should-not-win")

      on_exit(fn ->
        if previous, do: System.put_env("TERMINAL", previous), else: System.delete_env("TERMINAL")
      end)

      assert Dockd.Shell.open_terminal(launcher, "cmd", "chosen-emulator") == :ok
      assert File.read!(out) === "chosen-emulator"
    end
  end

  describe "open_window/6" do
    test "uses the given launcher path and reports success" do
      launcher = write_launcher!("#!/bin/sh\nexit 0\n")
      inst = %Instance{name: "web", shell: "/bin/sh"}

      assert Dockd.Shell.open_window(inst, launcher, "xterm", @docker, @endpoint) == :ok
    end
  end

  describe "default_launcher_path/0" do
    test "names the bundled launcher, as an explicit opt-in" do
      assert Dockd.Shell.default_launcher_path() =~ "open-shell"
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
