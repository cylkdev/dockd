defmodule Dockd.SpecTest do
  use ExUnit.Case, async: true

  alias Dockd.Error
  alias Dockd.Spec

  describe "new/3" do
    test "sets image and keeps the instance name unprefixed" do
      assert {:ok, spec} = Spec.new("busybox:latest", "my-box")
      assert spec.image === "busybox:latest"
      assert spec.instance_name === "my-box"
    end

    test "carries :description onto the struct when provided" do
      assert {:ok, spec} = Spec.new("busybox:latest", "my-box", description: "a demo")
      assert spec.description === "a demo"
    end

    test "defaults :description to nil when not provided" do
      assert {:ok, spec} = Spec.new("busybox:latest", "my-box")
      assert spec.description === nil
    end

    test "defaults list and map fields when absent" do
      assert {:ok, spec} = Spec.new("busybox:latest", "my-box")
      assert spec.steps === []
      assert spec.repos === []
      assert spec.copy === []
      assert spec.env === []
      assert spec.mounts === []
      assert spec.labels === %{}
    end

    test "returns a :validate error instead of raising when the name is unusable" do
      for bad <- ["", nil, :atom] do
        assert {:error, %Error{phase: :validate, message: message}} =
                 Spec.new("busybox:latest", bad)

        assert message =~ "non-empty binary :instance_name"
      end
    end

    test "returns a :validate error when the image is unusable" do
      for bad <- ["", nil, :atom] do
        assert {:error, %Error{phase: :validate, message: message}} = Spec.new(bad, "my-box")
        assert message =~ "non-empty binary :image"
      end
    end

    # "foo" and "dockd-foo" would otherwise name the same container.
    test "rejects an instance name that already carries the dockd- prefix" do
      assert {:error, %Error{phase: :validate, message: message}} =
               Spec.new("busybox:latest", "dockd-my-box")

      assert message =~ "must not include the dockd- prefix"
    end

    test "rejects an instance name outside Docker's name grammar" do
      assert {:error, %Error{phase: :validate, message: message}} =
               Spec.new("busybox:latest", "-leading-dash")

      assert message =~ ":instance_name must match"
    end
  end

  describe "validate/1" do
    # @enforce_keys blocks an incomplete literal, but not an explicit nil, so the
    # pipeline re-runs this on the way in.
    test "catches a nil image on a hand-built struct" do
      spec = %Spec{image: nil, instance_name: "my-box"}

      assert {:error, %Error{phase: :validate, message: message}} = Spec.validate(spec)
      assert message =~ "non-empty binary :image"
    end

    test "catches a nil instance_name on a hand-built struct" do
      spec = %Spec{image: "busybox:latest", instance_name: nil}

      assert {:error, %Error{phase: :validate, message: message}} = Spec.validate(spec)
      assert message =~ "non-empty binary :instance_name"
    end

    test "accepts a well-formed struct" do
      assert :ok = Spec.validate(%Spec{image: "busybox:latest", instance_name: "my-box"})
    end

    test "rejects a relative :build dockerfile" do
      spec = %Spec{
        image: "busybox:latest",
        instance_name: "my-box",
        build: %{dockerfile: "Dockerfile"}
      }

      assert {:error, %Error{phase: :validate, message: message}} = Spec.validate(spec)
      assert message =~ ":build dockerfile must be an absolute path"
    end

    test "rejects a relative :build context" do
      spec = %Spec{
        image: "busybox:latest",
        instance_name: "my-box",
        build: %{dockerfile: "/abs/Dockerfile", context: "./ctx"}
      }

      assert {:error, %Error{phase: :validate, message: message}} = Spec.validate(spec)
      assert message =~ ":build context must be an absolute path"
    end

    test "accepts absolute :build paths, string- or atom-keyed" do
      assert :ok =
               Spec.validate(%Spec{
                 image: "busybox:latest",
                 instance_name: "my-box",
                 build: %{dockerfile: "/abs/Dockerfile", context: "/abs"}
               })

      assert :ok =
               Spec.validate(%Spec{
                 image: "busybox:latest",
                 instance_name: "my-box",
                 build: %{"dockerfile" => "/abs/Dockerfile"}
               })
    end
  end

  describe "from_attrs/1" do
    test "builds a Spec from a normalized attrs map" do
      assert {:ok, spec} =
               Spec.from_attrs(%{image: "node:20", instance_name: "my-box", shell: "mytool"})

      assert spec.image === "node:20"
      assert spec.shell === "mytool"
      assert spec.instance_name === "my-box"
    end

    # Same validation body as new/3, so the same error rather than a crash.
    test "returns a :validate error when instance_name is missing from attrs" do
      assert {:error, %Error{phase: :validate, message: message}} =
               Spec.from_attrs(%{image: "x"})

      assert message =~ "non-empty binary :instance_name"
    end

    test "returns a :validate error when image is missing from attrs" do
      assert {:error, %Error{phase: :validate, message: message}} =
               Spec.from_attrs(%{instance_name: "my-box"})

      assert message =~ "non-empty binary :image"
    end

    test "carries :description through from attrs" do
      assert {:ok, spec} =
               Spec.from_attrs(%{image: "x", instance_name: "my-box", description: "a demo"})

      assert spec.description === "a demo"
    end
  end

  describe "option_keys/0" do
    test "does not claim :instance_name, which is positional" do
      refute :instance_name in Spec.option_keys()
      refute :image in Spec.option_keys()
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
