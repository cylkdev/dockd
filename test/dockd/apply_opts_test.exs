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
      refute err.phase === :validate
    end
  end

  describe "required positional inputs" do
    test "rejects a spec whose instance_name is nil" do
      spec = %Spec{image: "busybox:1.37.0", instance_name: nil}

      assert {:error, err} = Dockd.apply(spec, @endpoint, false, %{}, @tmp)
      assert err.phase === :validate
      assert err.message =~ "non-empty binary :instance_name"
    end

    test "rejects a missing or malformed endpoint before dialling anything" do
      {:ok, spec} = Spec.new("busybox:1.37.0", "smoke")

      for bad <- [nil, "", :atom] do
        assert {:error, err} = Dockd.apply(spec, bad, false, %{}, @tmp)
        assert err.phase === :validate
        assert err.message =~ "a Docker endpoint is required"
      end
    end

    # The old code treated an absent flag as `true`, so forgetting it granted
    # maximum host exposure. No clause can do that now.
    test "rejects a non-boolean disk_mount_enabled rather than defaulting it" do
      {:ok, spec} = Spec.new("busybox:1.37.0", "smoke")

      assert {:error, err} = Dockd.apply(spec, @endpoint, nil, %{}, @tmp)
      assert err.phase === :validate
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

  describe "conditionally required host tooling" do
    test "a spec with :repos needs git_path and git_env" do
      {:ok, spec} =
        Spec.new("busybox:1.37.0", "smoke",
          repos: [%{url: "https://example.com/r.git", dest: "/work"}]
        )

      assert {:error, err} = Dockd.apply(spec, @endpoint, true, %{}, @tmp)
      assert err.phase === :validate
      assert err.message =~ "needs git"
      assert err.message =~ ":git_path"
    end

    test "a spec with :copy needs tar_path and tar_env" do
      {:ok, spec} =
        Spec.new("busybox:1.37.0", "smoke", copy: [%{src: "/etc/hosts", dest: "/tmp/hosts"}])

      assert {:error, err} = Dockd.apply(spec, @endpoint, true, %{}, @tmp)
      assert err.phase === :validate
      assert err.message =~ "needs tar"
      assert err.message =~ ":tar_path"
    end

    test "a spec that copies nothing needs no tooling and gets as far as the daemon" do
      {:ok, spec} = Spec.new("busybox:1.37.0", "smoke")

      # Fails on the unreachable endpoint, not on validation — which is the point.
      assert {:error, err} = Dockd.apply(spec, @endpoint, false, %{}, @tmp)
      refute err.phase === :validate
    end

    # disk_mount_enabled: false strips :copy, so the tar requirement goes with it.
    test "disk_mount_enabled false strips the copy that would have needed tar" do
      {:ok, spec} =
        Spec.new("busybox:1.37.0", "smoke", copy: [%{src: "/etc/hosts", dest: "/tmp/hosts"}])

      assert {:error, err} = Dockd.apply(spec, @endpoint, false, %{}, @tmp)
      refute err.message =~ "needs tar"
    end
  end
end
