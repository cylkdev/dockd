defmodule DockdCLI.JsonE2ETest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "instance list --json prints a JSON array on stdout" do
    out = capture_io(fn -> assert DockdCLI.CLI.run(["instance", "list", "--json"]) == :ok end)
    assert is_list(Jason.decode!(out))
  end

  test "info --json prints a JSON object on stdout" do
    out = capture_io(fn -> assert DockdCLI.CLI.run(["info", "--json"]) == :ok end)
    assert is_map(Jason.decode!(out))
  end
end
