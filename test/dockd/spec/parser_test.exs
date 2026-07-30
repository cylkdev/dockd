defmodule Dockd.Spec.ParserTest do
  use ExUnit.Case, async: true

  alias Dockd.Spec.Parser

  describe "parse/1" do
    test "decodes a valid object" do
      json = ~s({"instance_name": "demo", "image": "node:20", "shell": "bash"})

      assert {:ok, %{"instance_name" => "demo", "image" => "node:20", "shell" => "bash"}} =
               Parser.parse(json)
    end

    test "accepts an optional description" do
      json = ~s({"instance_name": "demo", "description": "a demo", "image": "node:20"})

      assert {:ok, decoded} = Parser.parse(json)
      assert decoded["description"] === "a demo"
    end

    test "leaves nested values untouched" do
      json =
        ~s({"instance_name": "demo", "image": "x", "steps": [{"step_name": "hi", "cmd": ["echo", "hi"]}]})

      assert {:ok, decoded} = Parser.parse(json)
      assert decoded["steps"] === [%{"step_name" => "hi", "cmd" => ["echo", "hi"]}]
    end

    test "errors on invalid JSON" do
      assert {:error, error} = Parser.parse("not json")
      assert error.phase === :validate
      assert error.message =~ "invalid JSON"
    end

    test "errors when the top level is not an object" do
      assert {:error, error} = Parser.parse("[1,2,3]")
      assert error.phase === :validate
      assert error.message =~ "must be an object"
    end

    test "errors on unknown top-level key" do
      json = ~s({"instance_name": "demo", "image": "x", "bogus": true})

      assert {:error, error} = Parser.parse(json)
      assert error.phase === :validate
      assert error.message =~ "unknown package key"
    end

    test "names the replacement when a package still uses the old \"name\" key" do
      assert {:error, error} = Parser.parse(~s({"name": "demo", "image": "x"}))
      assert error.phase === :validate
      assert error.message =~ ~s(key "name" was renamed to "instance_name")
    end

    test "leaves an env entry's own \"name\" alone" do
      json =
        ~s({"instance_name": "demo", "image": "x", "env": [{"name": "FOO", "optional": true}]})

      assert {:ok, decoded} = Parser.parse(json)
      assert decoded["env"] === [%{"name" => "FOO", "optional" => true}]
    end

    test "errors when description is not a string" do
      json = ~s({"instance_name": "demo", "description": 7, "image": "x"})

      assert {:error, error} = Parser.parse(json)
      assert error.phase === :validate
      assert error.message =~ ~s("description" must be a string)
    end
  end

  describe "parse_file/1" do
    test "reads and parses a file's contents" do
      path =
        Path.join(System.tmp_dir!(), "dockd-source-#{System.unique_integer([:positive])}.json")

      File.write!(path, ~s({"instance_name": "x", "image": "busybox"}))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{"instance_name" => "x", "image" => "busybox"}} = Parser.parse_file(path)
    end

    test "wraps a missing file into a :validate-phase Dockd.Error" do
      assert {:error, error} = Parser.parse_file("/no/such/file.json")
      assert error.phase === :validate
      assert error.message =~ "could not read file"
    end

    # Presence and usability of "image" / "instance_name" are semantic, not
    # structural, so they belong to Dockd.Spec.validate/1 — one rule, one place,
    # one error shape for every construction path. Parser deliberately accepts
    # these documents; the load path is what rejects them (see the describe
    # below).
    test "accepts a document missing image or instance_name — that is Spec's rule" do
      assert {:ok, _} = Parser.parse(~s({"image": "x"}))
      assert {:ok, _} = Parser.parse(~s({"instance_name": "demo", "shell": "/bin/sh"}))
      assert {:ok, _} = Parser.parse(~s({"instance_name": "", "image": "x"}))
    end
  end

  # Where those rules actually live now: the whole read path, which is what a
  # caller of Dockd.apply_package/7 goes through.
  describe "the load path rejects what Parser passes through" do
    setup do
      dir = Path.join(System.tmp_dir!(), "dockd-parser-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "pkg"))
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, root: dir}
    end

    test "a missing instance_name", %{root: root} do
      write(root, ~s({"image": "x"}))

      assert {:error, error} = Dockd.load_package_spec(root, "pkg", %{})
      assert error.phase === :validate
      assert error.message =~ "non-empty binary :instance_name"
    end

    test "an empty or non-string instance_name", %{root: root} do
      for bad <- [~s(""), "42"] do
        write(root, ~s({"instance_name": #{bad}, "image": "x"}))

        assert {:error, error} = Dockd.load_package_spec(root, "pkg", %{})
        assert error.message =~ "non-empty binary :instance_name"
      end
    end

    test "a missing or non-string image", %{root: root} do
      for doc <- [
            ~s({"instance_name": "demo", "shell": "/bin/sh"}),
            ~s({"instance_name": "demo", "image": 42})
          ] do
        write(root, doc)

        assert {:error, error} = Dockd.load_package_spec(root, "pkg", %{})
        assert error.message =~ "non-empty binary :image"
      end
    end

    # The file path is added at the boundary, so an error names the package that
    # caused it even though the rule itself lives in Dockd.Spec.
    test "names the offending file in the message", %{root: root} do
      write(root, ~s({"image": "x"}))

      assert {:error, error} = Dockd.load_package_spec(root, "pkg", %{})
      assert error.message =~ Path.join([root, "pkg", "package.json"])
    end

    defp write(root, body) do
      File.write!(Path.join([root, "pkg", "package.json"]), body)
    end
  end
end
