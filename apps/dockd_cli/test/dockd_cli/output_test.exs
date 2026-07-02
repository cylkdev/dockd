defmodule DockdCli.OutputTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias DockdCli.Output

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
end
