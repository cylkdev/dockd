defmodule Dockd.EnvTest do
  # Async-safe now: `host_env` is an argument, so nothing here touches the
  # process environment to set up a case.
  use ExUnit.Case, async: true

  alias Dockd.Error

  # Validation runs before anything is dialled, so this endpoint is never used.
  @endpoint "unix:///nonexistent/docker.sock"
  @tmp "/tmp"

  describe ":env resolution against host_env" do
    test "fails before any Docker call when a bare name is absent from host_env" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               apply_env(["DOCKD_DEFINITELY_UNSET"], %{})

      assert msg =~ "DOCKD_DEFINITELY_UNSET"
      assert msg =~ "absent from host_env"
    end

    test "resolves a bare name that host_env supplies" do
      assert {:error, %Error{phase: phase}} =
               apply_env(["DOCKD_TEST_BARE_OK"], %{"DOCKD_TEST_BARE_OK" => "host_val"})

      refute phase === :validate
    end

    test "passes a literal NAME=value entry through without any lookup" do
      assert {:error, %Error{phase: phase}} = apply_env(["LITERAL=value"], %{})
      refute phase === :validate
    end

    # The point of the change: an empty host_env means a package or spec can
    # reach nothing from the host, no matter what the real process environment
    # holds.
    test "an empty host_env resolves nothing, even for names the process defines" do
      assert {:error, %Error{phase: :validate, message: msg}} = apply_env(["PATH"], %{})
      assert msg =~ "absent from host_env"
    end

    test "rejects non-string, non-tuple entries with a clear error" do
      assert {:error, %Error{phase: :validate, message: msg}} = apply_env([:not_a_string], %{})
      assert msg =~ ":env entries must be strings or"
    end

    test "rejects a non-list :env" do
      assert {:error, %Error{phase: :validate, message: msg}} = apply_env("FOO", %{})
      assert msg =~ ":env must be a list"
    end

    test "{name, value: literal} resolves without a host lookup" do
      assert {:error, %Error{phase: phase}} =
               apply_env([{"DOCKD_TEST_VALUE_SHAPE", value: "literal"}], %{})

      refute phase === :validate
    end

    test "{name, default: ...} succeeds at validate when host_env lacks the name" do
      assert {:error, %Error{phase: phase}} =
               apply_env([{"DOCKD_TEST_FALLBACK", default: "fallback"}], %{})

      refute phase === :validate
    end

    test "{name, optional: true} resolves at validate when host_env lacks the name" do
      assert {:error, %Error{phase: phase}} =
               apply_env([{"DOCKD_TEST_OPTIONAL", optional: true}], %{})

      refute phase === :validate
    end

    test "required passthrough (bare-name tuple) errors when host_env lacks the name" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               apply_env([{"DOCKD_TEST_REQUIRED", []}], %{})

      assert msg =~ "DOCKD_TEST_REQUIRED"
      assert msg =~ "absent from host_env"
    end
  end

  describe ":default precedence" do
    # This is the inversion. Previously host_env was consulted first and won, so
    # a value the caller wrote down could be silently overridden by ambient
    # state. An explicit argument now outranks the environment.
    test "an explicit :default beats a value present in host_env" do
      {:ok, spec} =
        Dockd.Spec.new("busybox:1.37.0", "smoke",
          env: [{"DOCKD_TEST_PRECEDENCE", default: "from-default"}]
        )

      host_env = %{"DOCKD_TEST_PRECEDENCE" => "from-host-env"}

      assert {:ok, resolved} = expand_env(spec, host_env)
      assert resolved === ["DOCKD_TEST_PRECEDENCE=from-default"]
    end

    test "host_env supplies the value when no :default is given" do
      {:ok, spec} =
        Dockd.Spec.new("busybox:1.37.0", "smoke", env: [{"DOCKD_TEST_PRECEDENCE", []}])

      host_env = %{"DOCKD_TEST_PRECEDENCE" => "from-host-env"}

      assert {:ok, resolved} = expand_env(spec, host_env)
      assert resolved === ["DOCKD_TEST_PRECEDENCE=from-host-env"]
    end

    test ":value still beats both" do
      {:ok, spec} =
        Dockd.Spec.new("busybox:1.37.0", "smoke",
          env: [{"DOCKD_TEST_PRECEDENCE", value: "literal", default: "from-default"}]
        )

      host_env = %{"DOCKD_TEST_PRECEDENCE" => "from-host-env"}

      assert {:ok, resolved} = expand_env(spec, host_env)
      assert resolved === ["DOCKD_TEST_PRECEDENCE=literal"]
    end
  end

  describe ":mounts validation" do
    test "rejects :binds (removed) at the unknown-option check" do
      assert {:error, %Error{phase: :validate, message: msg}} = apply_opts(binds: ["/h:/c"])
      assert msg =~ "unknown option"
      assert msg =~ ":binds"
    end

    test "rejects :inherit_env (removed) at the unknown-option check" do
      assert {:error, %Error{phase: :validate, message: msg}} = apply_opts(inherit_env: ["FOO"])
      assert msg =~ "unknown option"
      assert msg =~ ":inherit_env"
    end

    test "rejects malformed string entries" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               apply_spec_opts(mounts: ["bad-mount-no-colon"])

      assert msg =~ "invalid :mounts entry"
    end

    test "rejects map entries without :target" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               apply_spec_opts(mounts: [%{type: "tmpfs"}])

      assert msg =~ ":mounts map entry requires"
    end

    test "rejects a non-list :mounts" do
      assert {:error, %Error{phase: :validate, message: msg}} = apply_spec_opts(mounts: "/h:/c")
      assert msg =~ ":mounts must be a list"
    end
  end

  # ---------------------------------------------------------------------------

  defp apply_env(env, host_env) do
    apply_image_with(host_env, env: env)
  end

  defp apply_spec_opts(spec_opts), do: apply_image_with(%{}, spec_opts)

  defp apply_opts(opts), do: apply_image_with(%{}, opts)

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
