defmodule Dockd.SpecTest do
  use ExUnit.Case, async: true

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

      assert spec.copy === []
      assert spec.env === []
      assert spec.mounts === []
      assert spec.labels === %{}
    end

    test "returns a :validate error instead of raising when the name is unusable" do
      for bad <- ["", nil, :atom] do
        assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
                 Spec.new("busybox:latest", bad)

        assert message =~ "non-empty binary :instance_name"
      end
    end

    test "returns a :validate error when the image is unusable" do
      for bad <- ["", nil, :atom] do
        assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} = Spec.new(bad, "my-box")
        assert message =~ "non-empty binary :image"
      end
    end

    # The provisioner merges :labels straight into the managed labels. It used to
    # hedge with `user_labels || %{}`, so a nil was accepted everywhere except
    # that merge; now the invariant is stated once, here.
    test "rejects labels that are not a map" do
      for bad <- [nil, [], "a=b"] do
        assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
                 Spec.new("busybox:latest", "my-box", labels: bad)

        assert message =~ ":labels must be a map"
      end
    end

    # "foo" and "dockd-foo" would otherwise name the same container.
    test "rejects an instance name that already carries the dockd- prefix" do
      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
               Spec.new("busybox:latest", "dockd-my-box")

      assert message =~ "must not include the dockd- prefix"
    end

    test "rejects an instance name outside Docker's name grammar" do
      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
               Spec.new("busybox:latest", "-leading-dash")

      assert message =~ ":instance_name must match"
    end
  end

  describe "validate/1" do
    # @enforce_keys blocks an incomplete literal, but not an explicit nil, so the
    # pipeline re-runs this on the way in.
    test "catches a nil image on a hand-built struct" do
      spec = %Spec{image: nil, instance_name: "my-box"}

      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} = Spec.validate(spec)
      assert message =~ "non-empty binary :image"
    end

    test "catches a nil instance_name on a hand-built struct" do
      spec = %Spec{image: "busybox:latest", instance_name: nil}

      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} = Spec.validate(spec)
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

      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} = Spec.validate(spec)
      assert message =~ ":build dockerfile must be an absolute path"
    end

    test "rejects a relative :build context" do
      spec = %Spec{
        image: "busybox:latest",
        instance_name: "my-box",
        build: %{dockerfile: "/abs/Dockerfile", context: "./ctx"}
      }

      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} = Spec.validate(spec)
      assert message =~ ":build context must be an absolute path"
    end

    test "accepts absolute :build paths" do
      assert :ok =
               Spec.validate(%Spec{
                 image: "busybox:latest",
                 instance_name: "my-box",
                 build: %{dockerfile: "/abs/Dockerfile", context: "/abs"}
               })
    end
  end

  describe "from_map/1" do
    test "builds a Spec from an atom-keyed map" do
      assert {:ok, spec} =
               Spec.from_map(%{
                 image: "node:20",
                 instance_name: "my-box",
                 shell: "mytool",
                 description: "a demo"
               })

      assert spec.image === "node:20"
      assert spec.instance_name === "my-box"
      assert spec.shell === "mytool"
      assert spec.description === "a demo"
    end

    # A string-keyed map fails every key at once, which reads as a pile of typos
    # unless the cause is named.
    test "rejects string keys and says why" do
      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
               Spec.from_map(%{"image" => "node:20", "instance_name" => "my-box"})

      assert message =~ ~S|unknown spec key(s): "image", "instance_name"|
      assert message =~ "Spec map keys must be atoms"
    end

    test "carries the collection fields through" do
      assert {:ok, spec} =
               Spec.from_map(%{
                 image: "node:20",
                 instance_name: "my-box",
                 env: ["FOO=bar", "HOME"],
                 mounts: ["/a:/b"],
                 labels: %{"team" => "platform"},
                 steps: [%{step_name: "s", cmd: ["true"]}],
                 copy: [%{src: "/a", dest: "/b"}]
               })

      assert spec.env === ["FOO=bar", "HOME"]
      assert spec.mounts === ["/a:/b"]
      assert spec.labels === %{"team" => "platform"}
      assert [%{step_name: "s"}] = spec.steps
      assert [%{src: "/a"}] = spec.copy
    end

    test "leaves absent keys at their struct defaults rather than nil" do
      assert {:ok, spec} = Spec.from_map(%{image: "x", instance_name: "my-box"})
      assert spec.steps === []
      assert spec.copy === []
      assert spec.env === []
      assert spec.mounts === []
      assert spec.labels === %{}
      assert spec.description === nil
    end

    # A typo that is silently ignored does nothing and says nothing, so it is
    # rejected at the boundary instead.
    test "rejects unknown keys, naming them and the valid set" do
      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
               Spec.from_map(%{image: "x", instance_name: "my-box", shel: "/bin/sh"})

      assert message =~ "unknown spec key(s): :shel"
      assert message =~ ":shell"
    end

    test "rejects the retired keys rather than silently dropping them" do
      for retired <- [:name, :repos, :label] do
        assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
                 Spec.from_map(%{:image => "x", :instance_name => "b", retired => "v"})

        assert message =~ "unknown spec key"
      end
    end

    # Same validation body as new/3, so the same error rather than a crash.
    test "returns a :validate error when instance_name is missing" do
      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} = Spec.from_map(%{image: "x"})

      assert message =~ "non-empty binary :instance_name"
    end

    test "returns a :validate error when image is missing" do
      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
               Spec.from_map(%{instance_name: "my-box"})

      assert message =~ "non-empty binary :image"
    end

    test "rejects an instance_name that already carries the dockd- prefix" do
      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
               Spec.from_map(%{image: "x", instance_name: "dockd-my-box"})

      assert message =~ "must not include the dockd- prefix"
    end

    # There is no package directory to resolve against, so a relative path would
    # fall back to the calling process's CWD.
    test "rejects a relative :build dockerfile or context path" do
      for key <- [:dockerfile, :context] do
        assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
                 Spec.from_map(%{
                   :image => "x",
                   :instance_name => "my-box",
                   :build => %{key => "./relative"}
                 })

        assert message =~ "absolute"
      end
    end

    test "accepts an absolute :build path" do
      assert {:ok, spec} =
               Spec.from_map(%{
                 image: "x",
                 instance_name: "my-box",
                 build: %{dockerfile: "/abs/Dockerfile"}
               })

      assert spec.build === %{dockerfile: "/abs/Dockerfile"}
    end

    # The contract is a tagged error for bad *values*, never a raise.
    test "reports a non-map argument instead of raising" do
      for bad <- ["a string", nil, [image: "x"]] do
        assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} = Spec.from_map(bad)
        assert message =~ "requires a map"
      end
    end

    test "reports a key that is not an atom instead of raising" do
      assert {:error, %ErrorMessage{message: message, details: %{phase: :validate}}} =
               Spec.from_map(%{:image => "x", :instance_name => "b", 1 => "v"})

      assert message =~ "unknown spec key"
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
