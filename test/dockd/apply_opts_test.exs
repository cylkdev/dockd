defmodule Dockd.ApplyOptsTest do
  use ExUnit.Case, async: true

  alias Dockd.Spec

  # These never reach the daemon: option and spec validation happen before
  # provisioning, so the unreachable endpoint below is never dialled.
  @endpoint "unix:///nonexistent/docker.sock"
  @tmp "/tmp"

  describe "caller options" do
    # An unrecognized key is ignored, as in any keyword-option API — it does not
    # become a :validate error, so the call proceeds to the daemon.
    test "ignores an option outside option_keys/0" do
      {:ok, spec} = Spec.new("busybox:1.37.0", "smoke")

      assert {:error, err} = Dockd.apply(spec, @endpoint, false, %{}, @tmp, scoket: "/x")
      refute err.details.phase === :validate
    end
  end

  describe "required positional inputs" do
    test "rejects a spec whose instance_name is nil" do
      spec = %Spec{image: "busybox:1.37.0", instance_name: nil}

      assert {:error, err} = Dockd.apply(spec, @endpoint, false, %{}, @tmp)
      assert err.details.phase === :validate
      assert err.message =~ "non-empty binary :instance_name"
    end

    test "rejects a missing or malformed endpoint before dialling anything" do
      {:ok, spec} = Spec.new("busybox:1.37.0", "smoke")

      for bad <- [nil, "", :atom] do
        assert {:error, err} = Dockd.apply(spec, bad, false, %{}, @tmp)
        assert err.details.phase === :validate
        assert err.message =~ "a Docker endpoint is required"
      end
    end

    # The old code treated an absent flag as `true`, so forgetting it granted
    # maximum host exposure. No clause can do that now.
    test "rejects a non-boolean disk_mount_enabled rather than defaulting it" do
      {:ok, spec} = Spec.new("busybox:1.37.0", "smoke")

      assert {:error, err} = Dockd.apply(spec, @endpoint, nil, %{}, @tmp)
      assert err.details.phase === :validate
      assert err.message =~ "disk_mount_enabled must be a boolean"
    end

    test "rejects a missing or relative temp_root" do
      {:ok, spec} = Spec.new("busybox:1.37.0", "smoke")

      assert {:error, err} = Dockd.apply(spec, @endpoint, false, %{}, nil)
      assert err.message =~ "a host temp_root is required"

      assert {:error, err} = Dockd.apply(spec, @endpoint, false, %{}, "relative/dir")
      assert err.message =~ "temp_root must be an absolute path"
    end
  end

  # A spec with :copy used to need :tar_path and :tar_env, and was rejected at
  # :validate without them. The archive is built in-process now, so there is no
  # host tooling to require and no option to forget.
  describe "no host tooling is required" do
    test "a spec with :copy validates and gets as far as the daemon" do
      {:ok, spec} =
        Spec.new("busybox:1.37.0", "smoke", copy: [%{src: "/etc/hosts", dest: "/tmp/hosts"}])

      # Fails on the unreachable endpoint, not on validation — which is the point.
      assert {:error, err} = Dockd.apply(spec, @endpoint, true, %{}, @tmp)
      refute err.details.phase === :validate
    end

    test "a spec that copies nothing gets as far as the daemon too" do
      {:ok, spec} = Spec.new("busybox:1.37.0", "smoke")

      assert {:error, err} = Dockd.apply(spec, @endpoint, false, %{}, @tmp)
      refute err.details.phase === :validate
    end
  end
end
