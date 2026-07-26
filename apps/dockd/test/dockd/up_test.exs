defmodule Dockd.UpTest do
  # Integration test: requires a running Docker daemon. Exercises the
  # install-if-missing + idempotent-start flow behind `dockd instance up`.
  use ExUnit.Case, async: false

  alias Dockd.Instance

  @image "busybox:1.37.0"

  setup do
    root = Path.join(System.tmp_dir!(), "dockd-up-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, opts: [packages_path: root]}
  end

  test "provisions when absent, then is idempotent on the second call", %{root: root, opts: opts} do
    name = unique_name()
    write_package(root, name, @image, shell: "/bin/sh")
    on_exit(fn -> Dockd.destroy(name, opts) end)

    assert {:ok, %{package: :present, action: :created, instance: %Instance{} = inst}} =
             Dockd.up(name, opts)

    assert inst.running?
    assert {:ok, true} = Dockd.running?(name, opts)

    # Second call: unchanged spec, still running -> no-op.
    assert {:ok, %{action: :running, instance: inst2}} = Dockd.up(name, opts)
    assert inst2.id === inst.id
  end

  test "starts an existing but stopped instance without recreating it", %{root: root, opts: opts} do
    name = unique_name()
    write_package(root, name, @image, shell: "/bin/sh")
    on_exit(fn -> Dockd.destroy(name, opts) end)

    assert {:ok, %{action: :created, instance: inst}} = Dockd.up(name, opts)
    assert :ok = Dockd.stop(inst, opts)

    assert {:ok, %{action: :started, instance: started}} = Dockd.up(name, opts)
    assert started.id === inst.id
    assert started.running?
  end

  test "recreates the instance when the package spec changes", %{root: root, opts: opts} do
    name = unique_name()
    write_package(root, name, @image, shell: "/bin/sh")
    on_exit(fn -> Dockd.destroy(name, opts) end)

    assert {:ok, %{action: :created, instance: inst}} = Dockd.up(name, opts)

    # Rewrite the package with a different shell -> drift.
    write_package(root, name, @image, shell: "/bin/cat")

    assert {:ok, %{action: :recreated, instance: recreated}} = Dockd.up(name, opts)
    refute recreated.id === inst.id
    assert recreated.shell === "/bin/cat"
  end

  test "errors when the package is absent and no --source is given", %{opts: opts} do
    assert {:error, %Dockd.Error{phase: :validate, message: message}} =
             Dockd.up("does-not-exist", opts)

    assert message =~ "not installed"
  end

  defp write_package(root, name, image, spec_fields) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    body = Enum.into(spec_fields, %{"name" => name, "image" => image})
    File.write!(Path.join(dir, "package.json"), Jason.encode!(body))
  end

  defp unique_name, do: "up-test-#{System.unique_integer([:positive])}"
end
