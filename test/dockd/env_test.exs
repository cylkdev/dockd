defmodule Dockd.EnvTest do
  use ExUnit.Case, async: false

  alias Dockd.Error
  alias Dockd.Package

  describe "prepare/2 with :env (Elixir API)" do
    test "fails before any Docker call when a bare-name var is unset" do
      System.delete_env("DOCKD_DEFINITELY_UNSET")

      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.prepare("any-image", env: ["DOCKD_DEFINITELY_UNSET"])

      assert msg =~ "DOCKD_DEFINITELY_UNSET"
      assert msg =~ "unset host var"
    end

    test "rejects non-string, non-tuple entries with a clear error" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.prepare("any-image", env: [:not_a_string])

      assert msg =~ ":env entries must be strings or"
    end

    test "rejects a non-list :env" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.prepare("any-image", env: "FOO")

      assert msg =~ ":env must be a list"
    end

    test "{name, default: ...} succeeds at validate when the host var is unset" do
      System.delete_env("DOCKD_TEST_FALLBACK")

      assert {:error, %Error{phase: phase}} =
               Dockd.prepare("definitely-not-an-image",
                 env: [{"DOCKD_TEST_FALLBACK", default: "fallback"}]
               )

      refute phase === :validate
    end

    test "rejects :inherit_env (removed) at the unknown-option check" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.prepare("any-image", inherit_env: ["FOO"])

      assert msg =~ "unknown option"
      assert msg =~ ":inherit_env"
    end

    test "{name, value: literal} resolves without a host lookup" do
      System.delete_env("DOCKD_TEST_VALUE_SHAPE")

      assert {:error, %Error{phase: phase}} =
               Dockd.prepare("definitely-not-an-image",
                 env: [{"DOCKD_TEST_VALUE_SHAPE", value: "literal"}]
               )

      refute phase === :validate
    end

    test "{name, optional: true} resolves at validate when host is unset" do
      System.delete_env("DOCKD_TEST_OPTIONAL")

      assert {:error, %Error{phase: phase}} =
               Dockd.prepare("definitely-not-an-image",
                 env: [{"DOCKD_TEST_OPTIONAL", optional: true}]
               )

      refute phase === :validate
    end

    test "bare-string and literal-string entries still pass validate (regression)" do
      System.put_env("DOCKD_TEST_BARE_OK", "host_val")
      on_exit(fn -> System.delete_env("DOCKD_TEST_BARE_OK") end)

      assert {:error, %Error{phase: phase}} =
               Dockd.prepare("definitely-not-an-image",
                 env: ["DOCKD_TEST_BARE_OK", "LITERAL=value"]
               )

      refute phase === :validate
    end

    test "required passthrough (bare-name tuple) errors when host is unset" do
      System.delete_env("DOCKD_TEST_REQUIRED")

      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.prepare("any-image", env: [{"DOCKD_TEST_REQUIRED", []}])

      assert msg =~ "DOCKD_TEST_REQUIRED"
      assert msg =~ "unset host var"
    end
  end

  describe "JSON env round-trip through Dockd.Package.load/1 + Dockd.prepare/2" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "dockd-env-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      vars = ~w(DOCKD_E2E_FOO DOCKD_E2E_BAR DOCKD_E2E_BAZ DOCKD_E2E_QUX)
      Enum.each(vars, &System.delete_env/1)
      on_exit(fn -> Enum.each(vars, &System.delete_env/1) end)

      {:ok, tmp_dir: tmp_dir}
    end

    defp write_pkg(tmp_dir, env_entries) do
      path = Path.join(tmp_dir, "pkg.json")
      json = Jason.encode!(%{"image" => "definitely-not-an-image", "env" => env_entries})
      File.write!(path, json)
      path
    end

    # Drive package -> prepare. When env resolution succeeds, prepare reaches
    # the pull phase (or beyond), giving us a non-:validate phase. When env
    # resolution fails, prepare returns :validate with the offending message.
    defp run(tmp_dir, env_entries) do
      path = write_pkg(tmp_dir, env_entries)
      assert {:ok, {image, opts}} = Package.load(path)
      Dockd.prepare(image, opts)
    end

    test "literal value resolves and reaches a non-validate phase", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_E2E_FOO", "host_set")

      assert {:error, %Error{phase: phase}} =
               run(tmp_dir, [%{"name" => "DOCKD_E2E_FOO", "value" => "literal"}])

      refute phase === :validate
    end

    test "required passthrough fails at validate when host is unset", %{tmp_dir: tmp_dir} do
      assert {:error, %Error{phase: :validate, message: msg}} =
               run(tmp_dir, [%{"name" => "DOCKD_E2E_FOO"}])

      assert msg =~ "DOCKD_E2E_FOO"
      assert msg =~ "unset host var"
    end

    test "required passthrough succeeds when host is set", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_E2E_FOO", "from_host")

      assert {:error, %Error{phase: phase}} = run(tmp_dir, [%{"name" => "DOCKD_E2E_FOO"}])
      refute phase === :validate
    end

    test "default with host set resolves to host value", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_E2E_FOO", "host_wins")

      assert {:error, %Error{phase: phase}} =
               run(tmp_dir, [%{"name" => "DOCKD_E2E_FOO", "default" => "fallback"}])

      refute phase === :validate
    end

    test "default with host unset falls back", %{tmp_dir: tmp_dir} do
      assert {:error, %Error{phase: phase}} =
               run(tmp_dir, [%{"name" => "DOCKD_E2E_FOO", "default" => "fallback"}])

      refute phase === :validate
    end

    test "optional with host set resolves", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_E2E_FOO", "host_set")

      assert {:error, %Error{phase: phase}} =
               run(tmp_dir, [%{"name" => "DOCKD_E2E_FOO", "optional" => true}])

      refute phase === :validate
    end

    test "optional with host unset is dropped (no validate failure)", %{tmp_dir: tmp_dir} do
      assert {:error, %Error{phase: phase}} =
               run(tmp_dir, [%{"name" => "DOCKD_E2E_FOO", "optional" => true}])

      refute phase === :validate
    end

    test "all four shapes coexist in one package", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_E2E_BAR", "bar_set")
      System.put_env("DOCKD_E2E_BAZ", "baz_set")
      System.put_env("DOCKD_E2E_QUX", "qux_set")

      entries = [
        %{"name" => "DOCKD_E2E_FOO", "value" => "literal"},
        %{"name" => "DOCKD_E2E_BAR"},
        %{"name" => "DOCKD_E2E_BAZ", "default" => "default_baz"},
        %{"name" => "DOCKD_E2E_QUX", "optional" => true}
      ]

      # Scenario 1: all hosts set (FOO uses value, others use host).
      assert {:error, %Error{phase: phase}} = run(tmp_dir, entries)
      refute phase === :validate

      # Scenario 2: BAZ + QUX unset — default kicks in for BAZ, QUX dropped.
      System.delete_env("DOCKD_E2E_BAZ")
      System.delete_env("DOCKD_E2E_QUX")
      assert {:error, %Error{phase: phase}} = run(tmp_dir, entries)
      refute phase === :validate

      # Scenario 3: required BAR also unset — validate error names BAR.
      System.delete_env("DOCKD_E2E_BAR")
      assert {:error, %Error{phase: :validate, message: msg}} = run(tmp_dir, entries)
      assert msg =~ "DOCKD_E2E_BAR"
    end
  end

  describe "prepare/2 with :mounts" do
    test "rejects :binds (removed) at the unknown-option check" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.prepare("any-image", binds: ["/h:/c"])

      assert msg =~ "unknown option"
      assert msg =~ ":binds"
    end

    test "rejects malformed string entries" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.prepare("any-image", mounts: ["bad-mount-no-colon"])

      assert msg =~ "invalid :mounts entry"
    end

    test "rejects map entries without :target" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.prepare("any-image", mounts: [%{type: "tmpfs"}])

      assert msg =~ ":mounts map entry requires"
    end

    test "rejects a non-list :mounts" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Dockd.prepare("any-image", mounts: "/h:/c")

      assert msg =~ ":mounts must be a list"
    end
  end
end
