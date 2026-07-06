defmodule DockdCLI.OutputTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias DockdCLI.Output

  test "info writes a line to stdout" do
    assert capture_io(fn -> assert Output.info("hello") == :ok end) == "hello\n"
  end

  test "write emits raw bytes with no trailing newline" do
    assert capture_io(fn -> Output.write("abc") end) == "abc"
  end

  test "error writes to stderr" do
    assert capture_io(:stderr, fn -> assert Output.error("boom") == :ok end) == "boom\n"
  end

  test "table pads columns and prints header first" do
    out = capture_io(fn -> Output.table([{"a", "1"}, {"bb", "22"}], {"NAME", "N"}) end)
    assert out == "NAME  N\na     1\nbb    22\n"
  end

  test "json encodes a payload and writes one line to stdout" do
    out = capture_io(fn -> assert Output.json(%{a: 1, b: [2, 3]}) == :ok end)
    assert Jason.decode!(out) == %{"a" => 1, "b" => [2, 3]}
  end

  test "json_error wraps fields under an error key on stderr" do
    out =
      capture_io(:stderr, fn ->
        assert Output.json_error(%{phase: "create", message: "boom"}) == :ok
      end)

    assert Jason.decode!(out) == %{"error" => %{"phase" => "create", "message" => "boom"}}
  end
end
