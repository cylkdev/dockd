defmodule Mix.Tasks.Dockd.Package.ValidateTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Dockd.Package.Validate

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    tmp =
      Path.join([System.tmp_dir!(), "dockd-validate-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp}
  end

  describe "single-package validation" do
    test "prints OK for a structurally valid, fully-resolvable package", %{tmp: tmp} do
      path = write_package(tmp, ~s({"image": "busybox:1.37.0"}))

      Validate.run([path])

      assert_received {:mix_shell, :info, [line]}
      assert line =~ "OK"
    end

    test "prints FAIL with reason and raises on unset ${VAR}", %{tmp: tmp} do
      path =
        write_package(tmp, ~s({"image": "busybox:1.37.0", "mounts": ["${DOCKD_TEST_UNSET}:/x"]}))

      assert_raise Mix.Error, ~r/failed validation/, fn ->
        Validate.run([path])
      end

      assert_received {:mix_shell, :info, [line]}
      assert line =~ "FAIL"
      assert line =~ "DOCKD_TEST_UNSET"
    end

    test "prints FAIL and raises on structurally invalid JSON", %{tmp: tmp} do
      path = write_package(tmp, ~s({"shell": "/bin/sh"}))

      assert_raise Mix.Error, ~r/failed validation/, fn ->
        Validate.run([path])
      end

      assert_received {:mix_shell, :info, [line]}
      assert line =~ "FAIL"
      assert line =~ "missing required key"
    end

    test "prints FAIL and raises on unknown instance key", %{tmp: tmp} do
      path = write_package(tmp, ~s({"image": "busybox:1.37.0", "bogus": true}))

      assert_raise Mix.Error, ~r/failed validation/, fn ->
        Validate.run([path])
      end

      assert_received {:mix_shell, :info, [line]}
      assert line =~ "FAIL"
      assert line =~ "unknown instance key"
    end
  end

  describe "argv parsing" do
    test "rejects more than one positional argument" do
      assert_raise Mix.Error, ~r/Usage/, fn ->
        Validate.run(["a", "b"])
      end
    end
  end

  defp write_package(dir, json) do
    path = Path.join(dir, "package-#{System.unique_integer([:positive])}.json")
    File.write!(path, json)
    path
  end
end
