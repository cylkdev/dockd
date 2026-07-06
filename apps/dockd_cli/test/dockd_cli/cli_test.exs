defmodule DockdCLI.CLITest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  describe "run/1" do
    test "--version prints name and version, returns :ok" do
      out = capture_io(fn -> assert DockdCLI.CLI.run(["--version"]) == :ok end)
      assert out =~ "dockd"
    end

    test "no args prints help, returns :ok" do
      out = capture_io(fn -> assert DockdCLI.CLI.run([]) == :ok end)
      assert out =~ "USAGE" or out =~ "dockd"
    end

    test "unknown command reports to stderr and returns error" do
      err =
        capture_io(:stderr, fn ->
          send(self(), {:r, DockdCLI.CLI.run(["bogus-cmd"])})
        end)

      assert_received {:r, {:error, :usage}}
      assert err != ""
    end
  end

  test "spec parses `instance list`" do
    assert {:ok, [:instance, :list], _} = Optimus.parse(DockdCLI.CLI.spec(), ["instance", "list"])
  end

  test "spec parses `instance shell --name NAME` and routes to the Shell command" do
    assert {:ok, [:instance, :shell], parsed} =
             Optimus.parse(DockdCLI.CLI.spec(), ["instance", "shell", "--name", "smoke"])

    assert parsed.options.name == "smoke"
  end

  test "instance subcommands bind --name to :name" do
    for cmd <- ~w(stop start restart destroy logs inspect) do
      assert {:ok, [:instance, _leaf], parsed} =
               Optimus.parse(DockdCLI.CLI.spec(), ["instance", cmd, "--name", "foo"]),
             "#{cmd} should accept --name"

      assert parsed.options.name == "foo", "#{cmd} should bind --name to :name"
    end
  end

  test "instance destroy accepts --name together with --force" do
    assert {:ok, [:instance, :destroy], parsed} =
             Optimus.parse(DockdCLI.CLI.spec(), [
               "instance",
               "destroy",
               "--name",
               "foo",
               "--force"
             ])

    assert parsed.options.name == "foo"
    assert parsed.flags.force == true
  end

  test "spec parses `instance run` with flags" do
    assert {:ok, [:instance, :run], parsed} =
             Optimus.parse(DockdCLI.CLI.spec(), [
               "instance",
               "run",
               "--image",
               "busybox",
               "--name",
               "w"
             ])

    assert parsed.options.image == "busybox" and parsed.options.name == "w"
  end

  test "global --socket parses when given after the subcommand" do
    # Verified against deps/optimus/lib/optimus.ex: find_subcommand/3 only
    # descends into a subcommand when the *next* command-line token matches
    # a subcommand name, so a global option placed *before* the subcommand
    # name is treated as a top-level (unrecognized) argument and errors out.
    # Global options merge into each subcommand's own `options`/`flags`
    # lists (see Optimus.Builder.merge_globals_into_subcommand/2), so they
    # must appear after the subcommand on the command line and land in the
    # subcommand's own `parsed.options` map.
    assert {:ok, [:instance, :list], parsed} =
             Optimus.parse(DockdCLI.CLI.spec(), ["instance", "list", "--socket", "/x.sock"])

    assert parsed.options.socket == "/x.sock"
  end

  test "a global option placed before the subcommand is rejected by this Optimus version" do
    assert {:error, _reasons} =
             Optimus.parse(DockdCLI.CLI.spec(), ["--socket", "/x.sock", "instance", "list"])
  end

  test "global --json parses after the subcommand into flags" do
    assert {:ok, [:instance, :list], parsed} =
             Optimus.parse(DockdCLI.CLI.spec(), ["instance", "list", "--json"])

    assert parsed.flags.json == true
  end

  test "--json defaults to false when absent" do
    assert {:ok, [:instance, :list], parsed} =
             Optimus.parse(DockdCLI.CLI.spec(), ["instance", "list"])

    assert parsed.flags.json == false
  end

  test "ssh dial_stdio_script install binds --target to :user_at_host" do
    assert {:ok, [:ssh, :dial_stdio_script, :install], parsed} =
             Optimus.parse(DockdCLI.CLI.spec(), [
               "ssh",
               "dial_stdio_script",
               "install",
               "--target",
               "me@host"
             ])

    assert parsed.options.user_at_host == "me@host"
  end

  test "package validate binds --name to :name" do
    assert {:ok, [:package, :validate], parsed} =
             Optimus.parse(DockdCLI.CLI.spec(), ["package", "validate", "--name", "git"])

    assert parsed.options.name == "git"
  end

  test "dispatch routes to run_json and tags the format when --json is set" do
    {:ok, path, parsed} =
      Optimus.parse(DockdCLI.CLI.spec(), ["instance", "stop", "--json"])

    # no name, no --all -> the run_json usage error, proving the JSON path ran
    assert {:json, {:error, msg}} = DockdCLI.CLI.dispatch({path, parsed})
    assert msg =~ "Usage"
  end

  test "dispatch routes to run and tags :human without --json" do
    {:ok, path, parsed} = Optimus.parse(DockdCLI.CLI.spec(), ["instance", "stop"])
    assert {:human, {:error, _}} = DockdCLI.CLI.dispatch({path, parsed})
  end

  test "instance logs has no run_json/2, confirming it opts out of --json" do
    refute function_exported?(DockdCLI.Commands.Instance.Logs, :run_json, 2)
  end

  test "dispatch falls back to :human for `instance logs --json` (no run_json defined)" do
    {:ok, path, parsed} = Optimus.parse(DockdCLI.CLI.spec(), ["instance", "logs", "--json"])

    # no name -> the human run/2 usage error, proving the router fell back
    # instead of raising UndefinedFunctionError for a missing run_json/2.
    assert {:human, {:error, msg}} = DockdCLI.CLI.dispatch({path, parsed})
    assert msg =~ "Usage"
  end

  test "package install has no run_json/2, confirming it is out of JSON scope" do
    refute function_exported?(DockdCLI.Commands.Package.Install, :run_json, 2)
  end

  test "dispatch falls back to :human for `package install --type git --json` (no run_json defined)" do
    {:ok, path, parsed} =
      Optimus.parse(DockdCLI.CLI.spec(), ["package", "install", "--type", "git", "--json"])

    # missing --source -> the human run/2 usage error, proving the router
    # fell back instead of raising UndefinedFunctionError.
    assert {:human, {:error, _}} = DockdCLI.CLI.dispatch({path, parsed})
  end
end
