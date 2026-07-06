defmodule DockdCLI.Commands.Instance.RunTest do
  use ExUnit.Case, async: true
  alias DockdCLI.Commands.Instance.Run

  test "rejects --preset combined with --image" do
    assert {:error, msg} = Run.validate_source_flags(%{preset: "p", image: "busybox"})
    assert msg =~ "--preset"
  end

  test "rejects --package combined with --dockerfile" do
    assert {:error, msg} = Run.validate_source_flags(%{package: "p.json", dockerfile: "./D"})
    assert msg =~ "--package"
  end

  test "accepts a lone source flag" do
    assert Run.validate_source_flags(%{image: "busybox"}) == :ok
  end

  test "shell_hint points the user at the instance shell command (short name)" do
    assert Run.shell_hint(%Dockd.Instance{name: "dockd-smoke", shell: "/bin/sh"}) ==
             "dockd instance shell --name smoke"
  end

  test "run_json rejects conflicting source flags without a daemon" do
    assert {:error, msg} =
             DockdCLI.Commands.Instance.Run.run_json(%{preset: "p", package: "q"}, [])

    assert msg =~ "--preset cannot be combined"
  end

  test "run_json requires --name for an image source" do
    assert {:error, msg} = DockdCLI.Commands.Instance.Run.run_json(%{image: "busybox"}, [])
    assert msg =~ "--name is required"
  end
end
