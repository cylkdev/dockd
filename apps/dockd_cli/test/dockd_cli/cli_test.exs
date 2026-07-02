defmodule DockdCli.CLITest do
  use ExUnit.Case, async: true

  test "spec parses `instance list`" do
    assert {:ok, [:instance, :list], _} = Optimus.parse(DockdCli.CLI.spec(), ["instance", "list"])
  end

  test "spec parses `instance run` with flags" do
    assert {:ok, [:instance, :run], parsed} =
             Optimus.parse(DockdCli.CLI.spec(), [
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
             Optimus.parse(DockdCli.CLI.spec(), ["instance", "list", "--socket", "/x.sock"])

    assert parsed.options.socket == "/x.sock"
  end

  test "a global option placed before the subcommand is rejected by this Optimus version" do
    assert {:error, _reasons} =
             Optimus.parse(DockdCli.CLI.spec(), ["--socket", "/x.sock", "instance", "list"])
  end
end
