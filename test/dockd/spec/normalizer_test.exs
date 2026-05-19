defmodule Dockd.Spec.NormalizerTest do
  use ExUnit.Case, async: true

  alias Dockd.Spec.Normalizer

  describe "normalize/2" do
    test "converts string keys to atoms" do
      assert {:ok, %{name: "demo", image: "x", shell: "bash"}} =
               Normalizer.normalize(
                 %{"name" => "demo", "image" => "x", "shell" => "bash"},
                 "/tmp"
               )
    end

    test "carries description through when present" do
      assert {:ok, %{name: "demo", description: "a demo", image: "x"}} =
               Normalizer.normalize(
                 %{"name" => "demo", "description" => "a demo", "image" => "x"},
                 "/tmp"
               )
    end

    test "converts env entries into {name, opts} tuples" do
      assert {:ok, %{env: [{"FOO", []}]}} =
               Normalizer.normalize(
                 %{"name" => "demo", "image" => "x", "env" => [%{"name" => "FOO"}]},
                 "/tmp"
               )
    end

    test "preserves env entry options" do
      assert {:ok, %{env: [{"FOO", [optional: true]}]}} =
               Normalizer.normalize(
                 %{
                   "name" => "demo",
                   "image" => "x",
                   "env" => [%{"name" => "FOO", "optional" => true}]
                 },
                 "/tmp"
               )
    end

    test "rejects an env entry with an unknown key" do
      assert {:error, error} =
               Normalizer.normalize(
                 %{
                   "name" => "demo",
                   "image" => "x",
                   "env" => [%{"name" => "FOO", "extra" => "bad"}]
                 },
                 "/tmp"
               )

      assert error.phase === :validate
      assert error.message =~ "unknown key"
    end

    test "rejects an env entry that combines value and default" do
      assert {:error, error} =
               Normalizer.normalize(
                 %{
                   "name" => "demo",
                   "image" => "x",
                   "env" => [%{"name" => "FOO", "value" => "a", "default" => "b"}]
                 },
                 "/tmp"
               )

      assert error.message =~ "cannot coexist with"
    end

    test "resolves a relative build.dockerfile against package_dir" do
      assert {:ok, %{build: %{dockerfile: dockerfile}}} =
               Normalizer.normalize(
                 %{
                   "name" => "demo",
                   "image" => "x",
                   "build" => %{"dockerfile" => "Dockerfile"}
                 },
                 "/abs/pkg"
               )

      assert dockerfile === "/abs/pkg/Dockerfile"
    end

    test "leaves an absolute build.dockerfile untouched" do
      assert {:ok, %{build: %{dockerfile: "/absolute/path/Foo"}}} =
               Normalizer.normalize(
                 %{
                   "name" => "demo",
                   "image" => "x",
                   "build" => %{"dockerfile" => "/absolute/path/Foo"}
                 },
                 "/abs/pkg"
               )
    end

    test "resolves both build.dockerfile and build.context relative to package_dir" do
      assert {:ok, %{build: build}} =
               Normalizer.normalize(
                 %{
                   "name" => "demo",
                   "image" => "x",
                   "build" => %{"dockerfile" => "Dockerfile", "context" => "./sub"}
                 },
                 "/abs/pkg"
               )

      assert build.dockerfile === "/abs/pkg/Dockerfile"
      assert build.context === "/abs/pkg/sub"
    end

    test "rejects an unknown build key" do
      assert {:error, error} =
               Normalizer.normalize(
                 %{"name" => "demo", "image" => "x", "build" => %{"bogus" => true}},
                 "/tmp"
               )

      assert error.message =~ "unknown build key"
    end

    test "rejects a non-list :env" do
      assert {:error, error} =
               Normalizer.normalize(
                 %{"name" => "demo", "image" => "x", "env" => "FOO"},
                 "/tmp"
               )

      assert error.message =~ "must be a list"
    end

    test "leaves ${VAR} placeholders untouched" do
      assert {:ok, %{mounts: ["${HOME}/x:/y"]}} =
               Normalizer.normalize(
                 %{"name" => "demo", "image" => "x", "mounts" => ["${HOME}/x:/y"]},
                 "/tmp"
               )
    end
  end
end
