defmodule Dockd.Spec.ParserTest do
  use ExUnit.Case, async: true

  alias Dockd.Spec.Parser

  describe "parse/1" do
    test "decodes a valid object" do
      json = ~s({"name": "demo", "image": "node:20", "shell": "bash"})

      assert {:ok, %{"name" => "demo", "image" => "node:20", "shell" => "bash"}} =
               Parser.parse(json)
    end

    test "accepts an optional description" do
      json = ~s({"name": "demo", "description": "a demo", "image": "node:20"})

      assert {:ok, decoded} = Parser.parse(json)
      assert decoded["description"] === "a demo"
    end

    test "leaves nested values untouched" do
      json =
        ~s({"name": "demo", "image": "x", "steps": [{"label": "hi", "cmd": ["echo", "hi"]}]})

      assert {:ok, decoded} = Parser.parse(json)
      assert decoded["steps"] === [%{"label" => "hi", "cmd" => ["echo", "hi"]}]
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
      json = ~s({"name": "demo", "image": "x", "bogus": true})

      assert {:error, error} = Parser.parse(json)
      assert error.phase === :validate
      assert error.message =~ "unknown package key"
    end

    test "errors when name is missing" do
      assert {:error, error} = Parser.parse(~s({"image": "x"}))
      assert error.phase === :validate
      assert error.message =~ ~s(non-empty string "name")
    end

    test "errors when name is empty" do
      assert {:error, error} = Parser.parse(~s({"name": "", "image": "x"}))
      assert error.phase === :validate
      assert error.message =~ ~s(non-empty string "name")
    end

    test "errors when name is not a string" do
      assert {:error, error} = Parser.parse(~s({"name": 42, "image": "x"}))
      assert error.phase === :validate
      assert error.message =~ ~s(non-empty string "name")
    end

    test "errors when description is not a string" do
      json = ~s({"name": "demo", "description": 7, "image": "x"})

      assert {:error, error} = Parser.parse(json)
      assert error.phase === :validate
      assert error.message =~ ~s("description" must be a string)
    end

    test "errors when image is missing" do
      assert {:error, error} = Parser.parse(~s({"name": "demo", "shell": "/bin/sh"}))
      assert error.phase === :validate
      assert error.message =~ ~s(missing required key: "image")
    end

    test "errors when image is not a string" do
      assert {:error, error} = Parser.parse(~s({"name": "demo", "image": 42}))
      assert error.phase === :validate
      assert error.message =~ ~s("image" must be a string)
    end
  end
end
