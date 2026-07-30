defmodule Dockd.EnvTest do
  # Async-safe now: `host_env` is an argument, so nothing here touches the
  # process environment to set up a case.
  use ExUnit.Case, async: true


  # Validation runs before anything is dialled, so this endpoint is never used.
  @endpoint "unix:///nonexistent/docker.sock"
  @tmp "/tmp"

  describe ":env resolution against host_env" do
    test "fails before any Docker call when a bare name is absent from host_env" do
      assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} =
               apply_env(["DOCKD_DEFINITELY_UNSET"], %{})

      assert msg =~ "DOCKD_DEFINITELY_UNSET"
      assert msg =~ "absent from host_env"
    end

    test "resolves a bare name that host_env supplies" do
      assert {:error, %ErrorMessage{details: %{phase: phase}}} =
               apply_env(["DOCKD_TEST_BARE_OK"], %{"DOCKD_TEST_BARE_OK" => "host_val"})

      refute phase === :validate
    end

    test "passes a literal NAME=value entry through without any lookup" do
      assert {:error, %ErrorMessage{details: %{phase: phase}}} = apply_env(["LITERAL=value"], %{})
      refute phase === :validate
    end

    # The point of the change: an empty host_env means a package or spec can
    # reach nothing from the host, no matter what the real process environment
    # holds.
    test "an empty host_env resolves nothing, even for names the process defines" do
      assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} = apply_env(["PATH"], %{})
      assert msg =~ "absent from host_env"
    end

    test "rejects non-string entries with a clear error" do
      for bad <- [:not_a_string, {"NAME", value: "v"}, %{"name" => "NAME"}] do
        assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} = apply_env([bad], %{})
        assert msg =~ ":env entries must be strings"
      end
    end

    test "rejects a non-list :env" do
      assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} = apply_env("FOO", %{})
      assert msg =~ ":env must be a list"
    end

  end

  # Two shapes, no precedence rule: a literal, or a name read from host_env.
  describe ":env resolution has exactly two shapes" do
    test "a literal is passed through verbatim" do
      {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke", env: ["FOO=bar"])

      assert {:ok, ["FOO=bar"]} = expand_env(spec, %{})
    end

    test "a bare name is read from host_env" do
      {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke", env: ["FOO"])

      assert {:ok, ["FOO=from-host-env"]} = expand_env(spec, %{"FOO" => "from-host-env"})
    end

    # host_env is the only source. There is no :default to outrank it and no
    # :optional to excuse its absence, so a missing name is always an error.
    test "a bare name absent from host_env is a :validate error" do
      {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke", env: ["FOO"])

      assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} = expand_env(spec, %{})
      assert msg =~ "absent from host_env"
    end

    test "only the first = splits a literal, so values may contain =" do
      {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke", env: ["FOO=a=b"])

      assert {:ok, ["FOO=a=b"]} = expand_env(spec, %{})
    end

    test "resolves entries in order, keeping duplicates as written" do
      {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke", env: ["A=1", "B", "A=2"])

      assert {:ok, ["A=1", "B=host", "A=2"]} = expand_env(spec, %{"B" => "host"})
    end
  end

  describe ":mounts validation" do
    test "rejects malformed string entries" do
      assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} =
               apply_spec_opts(mounts: ["bad-mount-no-colon"])

      assert msg =~ "invalid :mounts entry"
    end

    test "rejects map entries without :target" do
      assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} =
               apply_spec_opts(mounts: [%{type: "tmpfs"}])

      assert msg =~ ":mounts map entry requires"
    end

    test "rejects a non-list :mounts" do
      assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} = apply_spec_opts(mounts: "/h:/c")
      assert msg =~ ":mounts must be a list"
    end
  end

  # ---------------------------------------------------------------------------

  defp apply_env(env, host_env) do
    apply_image_with(host_env, env: env)
  end

  defp apply_spec_opts(spec_opts), do: apply_image_with(%{}, spec_opts)

  defp apply_image_with(host_env, opts) do
    Dockd.apply_image(
      "definitely-not-an-image",
      unique_name(),
      @endpoint,
      true,
      host_env,
      @tmp,
      opts
    )
  end

  # The same resolution the pipeline runs, exposed so precedence is checkable
  # without a daemon.
  defp expand_env(spec, host_env), do: Dockd.Provisioner.resolve_env(spec, host_env)

  defp unique_name(prefix \\ "test") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
