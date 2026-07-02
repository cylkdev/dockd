defmodule DockdCli.Commands.Instance.RunTest do
  use ExUnit.Case, async: true
  alias DockdCli.Commands.Instance.Run

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

  test "connect_command builds a docker exec line" do
    assert Run.connect_command(%Dockd.Instance{name: "dockd-smoke", shell: "/bin/sh"}) ==
             "docker exec -it dockd-smoke /bin/sh"
  end
end
