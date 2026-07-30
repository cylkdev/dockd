defmodule Dockd.Spec.EncoderTest do
  use ExUnit.Case, async: true

  alias Dockd.Spec.Encoder
  alias Dockd.Spec.Parser

  describe "document/2" do
    # The name rules live in Dockd.Spec, so a scaffolded package is held to the
    # same grammar a loaded one is. These assert on Spec's messages.
    test "requires a non-empty instance name" do
      assert {:error, err} = Encoder.document("", [])
      assert err.phase === :validate
      assert err.message =~ "non-empty binary :instance_name"
    end

    test "rejects an instance name that cannot appear in an image tag" do
      assert {:error, err} = Encoder.document("my package", [])
      assert err.message =~ ":instance_name must match"
    end

    # Regression: the encoder used to keep its own copy of the name rules that
    # omitted the dockd- prefix rejection, so it scaffolded a package that then
    # failed at apply time.
    test "rejects an instance name that already carries the dockd- prefix" do
      assert {:error, err} = Encoder.document("dockd-greeter", [])
      assert err.phase === :validate
      assert err.message =~ "must not include the dockd- prefix"
    end

    test "defaults the image to a tag derived from the instance name" do
      assert {:ok, doc} = Encoder.document("greeter", [])
      assert doc["image"] === "dockd-greeter:latest"
    end

    # Silently emitting "dockd-greeter:latest" here would write a plausible
    # package that is not the one the caller asked for.
    test "reports a wrong-typed :image instead of defaulting it" do
      assert {:error, err} = Encoder.document("greeter", image: 42)
      assert err.phase === :validate
      assert err.message =~ ":image must be a non-empty string"
    end

    test "always wires the build to the generated Dockerfile" do
      assert {:ok, doc} = Encoder.document("greeter", [])
      assert doc["build"] === %{"dockerfile" => "Dockerfile"}
    end

    test "merges extra build keys over the generated dockerfile key" do
      assert {:ok, doc} =
               Encoder.document(
                 "greeter",
                 build: %{args: %{"A" => "1"}, nocache: true}
               )

      assert doc["build"]["dockerfile"] === "Dockerfile"
      assert doc["build"]["args"] === %{"A" => "1"}
      assert doc["build"]["nocache"] === true
    end

    test "omits keys the caller did not pass" do
      assert {:ok, doc} = Encoder.document("greeter", [])

      refute Map.has_key?(doc, "shell")
      refute Map.has_key?(doc, "env")
      refute Map.has_key?(doc, "steps")
      refute Map.has_key?(doc, "description")
    end

    test "omits keys whose value is empty" do
      assert {:ok, doc} = Encoder.document("greeter", env: [], steps: [])

      refute Map.has_key?(doc, "env")
      refute Map.has_key?(doc, "steps")
    end

    test "translates every env input shape into the JSON object shape" do
      assert {:ok, doc} =
               Encoder.document(
                 "greeter",
                 env: [
                   "LITERAL=one",
                   "INHERITED",
                   {"WITH_VALUE", value: "two"},
                   {"WITH_DEFAULT", default: "three"},
                   {"OPTIONAL", optional: true},
                   %{"name" => "ALREADY_A_MAP"}
                 ]
               )

      assert doc["env"] === [
               %{"name" => "LITERAL", "value" => "one"},
               %{"name" => "INHERITED"},
               %{"name" => "WITH_VALUE", "value" => "two"},
               %{"name" => "WITH_DEFAULT", "default" => "three"},
               %{"name" => "OPTIONAL", "optional" => true},
               %{"name" => "ALREADY_A_MAP"}
             ]
    end

    # Mutually-exclusive env options are the Normalizer's rule (see
    # normalizer_test.exs). The encoder no longer re-checks them; Packages.new/3
    # runs the encoded document back through the Normalizer before writing, and
    # packages_test.exs pins that end to end.
    test "encodes mutually exclusive env options without checking them" do
      assert {:ok, doc} =
               Encoder.document("greeter", env: [{"FOO", value: "a", default: "b"}])

      assert doc["env"] === [%{"name" => "FOO", "value" => "a", "default" => "b"}]
    end

    test "rejects a non-list env" do
      assert {:error, err} = Encoder.document("greeter", env: %{"FOO" => "bar"})
      assert err.message =~ ":env must be a list"
    end

    test "stringifies atom keys in passthrough values" do
      assert {:ok, doc} =
               Encoder.document(
                 "greeter",
                 steps: [%{step_name: "a", cmd: ["true"]}],
                 copy: [%{src: "/a", dest: "/b"}]
               )

      assert doc["steps"] === [%{"step_name" => "a", "cmd" => ["true"]}]
      assert doc["copy"] === [%{"src" => "/a", "dest" => "/b"}]
    end
  end

  describe "encode/1" do
    test "pretty-prints across multiple lines" do
      {:ok, doc} = Encoder.document("greeter", [])
      json = Encoder.encode(doc)

      assert json =~ "{\n"
      assert String.ends_with?(json, "}\n")
      assert length(String.split(json, "\n")) > 3
    end

    test "orders keys for readability rather than by map order" do
      {:ok, doc} =
        Encoder.document("greeter", shell: "/bin/sh", description: "d")

      keys =
        ~r/^  "(\w+)":/m
        |> Regex.scan(Encoder.encode(doc))
        |> Enum.map(fn [_, key] -> key end)

      assert keys === ["instance_name", "description", "image", "shell", "build"]
    end

    test "leads an env entry with its own name" do
      {:ok, doc} = Encoder.document("greeter", env: [{"FOO", optional: true}])

      assert Encoder.encode(doc) =~ ~s("name": "FOO",\n      "optional": true)
    end

    test "keeps scalar lists on one line" do
      {:ok, doc} =
        Encoder.document(
          "greeter",
          steps: [%{step_name: "a", cmd: ["sh", "-c", "true"]}]
        )

      assert Encoder.encode(doc) =~ ~s("cmd": ["sh", "-c", "true"])
    end

    test "breaks lists containing objects across lines" do
      {:ok, doc} = Encoder.document("greeter", env: [{"FOO", optional: true}])

      assert Encoder.encode(doc) =~ "\"env\": [\n"
    end

    test "round-trips back through the parser" do
      {:ok, doc} = Encoder.document("greeter", env: [{"FOO", optional: true}])

      assert {:ok, decoded} = Parser.parse(Encoder.encode(doc))
      assert decoded["instance_name"] === "greeter"
    end

    test "escapes strings through JSON rather than by hand" do
      {:ok, doc} = Encoder.document("greeter", description: ~s(a "quoted" \\ path))

      assert {:ok, decoded} = Parser.parse(Encoder.encode(doc))
      assert decoded["description"] === ~s(a "quoted" \\ path)
    end
  end

  describe "dockerfile/1" do
    test "generates FROM from the :from option" do
      assert Encoder.dockerfile(from: "busybox:1.37.0") === {:ok, "FROM busybox:1.37.0\n"}
    end

    test "defaults the base image" do
      assert Encoder.dockerfile([]) === {:ok, "FROM debian:trixie\n"}
    end

    test "uses an explicit body verbatim and ensures a trailing newline" do
      assert Encoder.dockerfile(dockerfile: "FROM x\nRUN y") === {:ok, "FROM x\nRUN y\n"}
    end

    test "does not double a trailing newline" do
      assert Encoder.dockerfile(dockerfile: "FROM x\n") === {:ok, "FROM x\n"}
    end

    # These used to fall back to the default, so `dockerfile: 42` silently wrote a
    # FROM debian:trixie image the caller never asked for.
    test "reports a wrong-typed :dockerfile instead of defaulting it" do
      assert {:error, err} = Encoder.dockerfile(dockerfile: 42)
      assert err.phase === :validate
      assert err.message =~ ":dockerfile must be a non-empty string"
    end

    test "reports a wrong-typed :from instead of defaulting it" do
      assert {:error, err} = Encoder.dockerfile(from: "")
      assert err.message =~ ":from must be a non-empty string"
    end
  end
end
