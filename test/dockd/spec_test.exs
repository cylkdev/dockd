defmodule Dockd.SpecTest do
  use ExUnit.Case, async: true

  alias Dockd.Spec

  describe "from_opts/2" do
    test "sets image and uses provided :name, prefixed with dockd-" do
      spec = Spec.from_opts("busybox:latest", name: "my-box")
      assert spec.image === "busybox:latest"
      assert spec.name === "dockd-my-box"
    end

    test "does not double-prefix a name that already starts with dockd-" do
      spec = Spec.from_opts("busybox:latest", name: "dockd-my-box")
      assert spec.name === "dockd-my-box"
    end

    test "raises when :name is missing" do
      assert_raise ArgumentError, ~r/non-empty binary :name/, fn ->
        Spec.from_opts("busybox:latest")
      end
    end

    test "raises when :name is empty or not a binary" do
      assert_raise ArgumentError, ~r/non-empty binary :name/, fn ->
        Spec.from_opts("busybox:latest", name: "")
      end

      assert_raise ArgumentError, ~r/non-empty binary :name/, fn ->
        Spec.from_opts("busybox:latest", name: :atom)
      end
    end

    test "carries :description onto the struct when provided" do
      spec = Spec.from_opts("busybox:latest", name: "my-box", description: "a demo")
      assert spec.description === "a demo"
    end

    test "defaults :description to nil when not provided" do
      spec = Spec.from_opts("busybox:latest", name: "my-box")
      assert spec.description === nil
    end
  end

  describe "from_attrs/1" do
    test "builds a Spec from a normalized attrs map with a name" do
      spec = Spec.from_attrs(%{image: "node:20", name: "my-box", shell: "mytool"})
      assert spec.image === "node:20"
      assert spec.shell === "mytool"
      assert spec.name === "dockd-my-box"
    end

    test "raises when :name is missing from attrs" do
      assert_raise ArgumentError, ~r/non-empty binary :name/, fn ->
        Spec.from_attrs(%{image: "x"})
      end
    end

    test "defaults list and map fields when absent" do
      spec = Spec.from_attrs(%{image: "x", name: "my-box"})
      assert spec.steps === []
      assert spec.repos === []
      assert spec.copy === []
      assert spec.env === []
      assert spec.mounts === []
      assert spec.labels === %{}
    end

    test "carries :description through from attrs" do
      spec = Spec.from_attrs(%{image: "x", name: "my-box", description: "a demo"})
      assert spec.description === "a demo"
    end
  end

  describe "prefix_name/1 and short_name/1" do
    test "prefix_name prepends dockd- when missing" do
      assert Spec.prefix_name("foo") === "dockd-foo"
    end

    test "prefix_name leaves names that already start with dockd-" do
      assert Spec.prefix_name("dockd-foo") === "dockd-foo"
    end

    test "short_name strips the dockd- prefix" do
      assert Spec.short_name("dockd-foo") === "foo"
    end

    test "short_name leaves names without the prefix" do
      assert Spec.short_name("foo") === "foo"
    end
  end

end
