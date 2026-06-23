defmodule Dockd.Tui.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Dockd.Tui.CLI

  describe "parse/1" do
    test "requires an instance" do
      assert {:error, "INSTANCE is required"} = CLI.parse([])
    end

    test "parses shell and Docker options" do
      assert {:ok, "work", opts} =
               CLI.parse([
                 "work",
                 "--shell",
                 "/bin/bash",
                 "--socket",
                 "/var/run/docker.sock",
                 "--host",
                 "tcp://docker.example",
                 "--api-version",
                 "1.43",
                 "--platform",
                 "linux/amd64",
                 "--network",
                 "front",
                 "--network",
                 "back",
                 "--network-mode",
                 "bridge"
               ])

      assert opts[:shell] === ["/bin/bash"]
      assert opts[:socket] === "/var/run/docker.sock"
      assert opts[:host] === "tcp://docker.example"
      assert opts[:api_version] === "1.43"
      assert opts[:platform] === "linux/amd64"
      assert opts[:networks] === ["front", "back"]
      assert opts[:network_mode] === "bridge"
    end

    test "returns usage for help" do
      assert {:help, usage} = CLI.parse(["--help"])
      assert usage =~ "Usage: dockd_tui INSTANCE"
    end
  end

  describe "run/2" do
    test "starts the shell TUI and waits for it" do
      parent = self()

      status =
        CLI.run(
          ["work", "--shell", "/bin/bash"],
          app_starter: fn :dockd_tui -> {:ok, [:dockd_tui]} end,
          starter: fn instance, opts ->
            send(parent, {:started, instance, opts})
            {:ok, self()}
          end,
          await: fn pid -> send(parent, {:awaited, pid}) end
        )

      assert status === 0
      assert_received {:started, "work", [shell: ["/bin/bash"]]}
      assert_received {:awaited, _pid}
    end

    test "prints errors and returns nonzero" do
      output =
        capture_io(:stderr, fn ->
          assert CLI.run([]) === 1
        end)

      assert output =~ "INSTANCE is required"
      assert output =~ "Usage: dockd_tui INSTANCE"
    end
  end
end
