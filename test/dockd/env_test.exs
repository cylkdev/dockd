defmodule Dockd.EnvTest do
  use ExUnit.Case

  alias Dockd.Error

  describe "apply/2 with :env (Elixir API)" do
    test "fails before any Docker call when a bare-name var is unset" do
      System.delete_env("DOCKD_DEFINITELY_UNSET")

      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.apply("any-image", env: ["DOCKD_DEFINITELY_UNSET"], name: unique_name())

      assert msg =~ "DOCKD_DEFINITELY_UNSET"
      assert msg =~ "unset host var"
    end

    test "rejects non-string, non-tuple entries with a clear error" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.apply("any-image", env: [:not_a_string], name: unique_name())

      assert msg =~ ":env entries must be strings or"
    end

    test "rejects a non-list :env" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.apply("any-image", env: "FOO", name: unique_name())

      assert msg =~ ":env must be a list"
    end

    test "{name, default: ...} succeeds at validate when the host var is unset" do
      System.delete_env("DOCKD_TEST_FALLBACK")

      assert {:error, %Error{phase: phase}} =
               Dockd.apply("definitely-not-an-image",
                 env: [{"DOCKD_TEST_FALLBACK", default: "fallback"}],
                 name: unique_name()
               )

      refute phase === :validate
    end

    test "rejects :inherit_env (removed) at the unknown-option check" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.apply("any-image", inherit_env: ["FOO"], name: unique_name())

      assert msg =~ "unknown option"
      assert msg =~ ":inherit_env"
    end

    test "{name, value: literal} resolves without a host lookup" do
      System.delete_env("DOCKD_TEST_VALUE_SHAPE")

      assert {:error, %Error{phase: phase}} =
               Dockd.apply("definitely-not-an-image",
                 env: [{"DOCKD_TEST_VALUE_SHAPE", value: "literal"}],
                 name: unique_name()
               )

      refute phase === :validate
    end

    test "{name, optional: true} resolves at validate when host is unset" do
      System.delete_env("DOCKD_TEST_OPTIONAL")

      assert {:error, %Error{phase: phase}} =
               Dockd.apply("definitely-not-an-image",
                 env: [{"DOCKD_TEST_OPTIONAL", optional: true}],
                 name: unique_name()
               )

      refute phase === :validate
    end

    test "bare-string and literal-string entries still pass validate (regression)" do
      System.put_env("DOCKD_TEST_BARE_OK", "host_val")
      on_exit(fn -> System.delete_env("DOCKD_TEST_BARE_OK") end)

      assert {:error, %Error{phase: phase}} =
               Dockd.apply("definitely-not-an-image",
                 env: ["DOCKD_TEST_BARE_OK", "LITERAL=value"],
                 name: unique_name()
               )

      refute phase === :validate
    end

    test "required passthrough (bare-name tuple) errors when host is unset" do
      System.delete_env("DOCKD_TEST_REQUIRED")

      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.apply("any-image", env: [{"DOCKD_TEST_REQUIRED", []}], name: unique_name())

      assert msg =~ "DOCKD_TEST_REQUIRED"
      assert msg =~ "unset host var"
    end
  end

  describe "apply/2 with :mounts" do
    test "rejects :binds (removed) at the unknown-option check" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.apply("any-image", binds: ["/h:/c"], name: unique_name())

      assert msg =~ "unknown option"
      assert msg =~ ":binds"
    end

    test "rejects malformed string entries" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.apply("any-image", mounts: ["bad-mount-no-colon"], name: unique_name())

      assert msg =~ "invalid :mounts entry"
    end

    test "rejects map entries without :target" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.apply("any-image", mounts: [%{type: "tmpfs"}], name: unique_name())

      assert msg =~ ":mounts map entry requires"
    end

    test "rejects a non-list :mounts" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.apply("any-image", mounts: "/h:/c", name: unique_name())

      assert msg =~ ":mounts must be a list"
    end
  end

  defp unique_name(prefix \\ "test") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
