defmodule Dockd.Spec.SourceTest do
  use ExUnit.Case, async: true

  alias Dockd.Spec.Source

  test "reads a file's contents" do
    path = Path.join(System.tmp_dir!(), "dockd-source-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"image": "x"}))
    on_exit(fn -> File.rm(path) end)

    assert {:ok, ~s({"image": "x"})} = Source.read_file(path)
  end

  test "wraps a missing file into a :validate-phase Dockd.Error" do
    assert {:error, error} = Source.read_file("/no/such/file.json")
    assert error.phase === :validate
    assert error.message =~ "could not read file"
  end
end
