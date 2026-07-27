defmodule Dockd.ApplyOptsTest do
  use ExUnit.Case, async: true

  alias Dockd.Spec

  # These never reach the daemon: option validation happens before provisioning.

  describe "apply/2 caller-option validation" do
    test "rejects an unknown caller option when given an image string" do
      assert {:error, err} = Dockd.apply("busybox:1.37.0", instance_name: "smoke", scoket: "/x")

      assert err.phase === :validate
      assert err.message =~ "unknown option"
    end

    test "rejects an unknown caller option when given a pre-built Spec" do
      spec = Spec.from_opts("busybox:1.37.0", instance_name: "smoke")

      assert {:error, err} = Dockd.apply(spec, scoket: "/x")

      assert err.phase === :validate
      assert err.message =~ "unknown option"
    end

    test "requires a non-empty :instance_name when given an image string" do
      assert {:error, err} = Dockd.apply("busybox:1.37.0")

      assert err.phase === :validate
      assert err.message =~ "requires a non-empty :instance_name option"
    end
  end
end
