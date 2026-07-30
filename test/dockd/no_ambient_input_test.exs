defmodule Dockd.NoAmbientInputTest do
  # Not async: this test deliberately sets the environment variables and app
  # config that dockd used to read, to prove they no longer have any effect.
  use ExUnit.Case, async: false

  @moduledoc false

  # The guarantee under test: with every legacy ambient source pointed at
  # garbage, operations driven purely by explicit arguments still succeed.
  #
  # This is the regression test for the whole "required inputs are arguments"
  # change. It cannot be expressed as a unit test of any single function —
  # what it checks is the absence of a read, across the library.

  setup do
    previous = %{
      env: System.get_env("DOCKD_PACKAGES_PATH"),
      config: Application.get_env(:dockd, :packages_path),
      docker_host: System.get_env("DOCKER_HOST")
    }

    System.put_env("DOCKD_PACKAGES_PATH", "/nonexistent/packages")
    System.put_env("DOCKER_HOST", "tcp://127.0.0.1:1")
    Application.put_env(:dockd, :packages_path, "/also/nonexistent")

    on_exit(fn ->
      restore("DOCKD_PACKAGES_PATH", previous.env)
      restore("DOCKER_HOST", previous.docker_host)

      case previous.config do
        nil -> Application.delete_env(:dockd, :packages_path)
        value -> Application.put_env(:dockd, :packages_path, value)
      end
    end)

    root = Path.join(System.tmp_dir!(), "dockd-ambient-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "the package lifecycle works entirely from arguments", %{root: root} do
    pkg = Path.join(root, "greeter")

    assert {:ok, %{instance_name: "greeter"}} =
             Dockd.new_package(pkg, "greeter", from: "busybox:1.37.0", shell: "/bin/sh")

    # Found under the root we named, not under DOCKD_PACKAGES_PATH or ~/.dockd.
    assert [%{name: "greeter", spec: {:ok, spec}}] = Dockd.list_packages(root)
    assert spec.instance_name === "greeter"

    assert {:ok, loaded} = Dockd.load_package_spec(root, "greeter", %{})
    assert loaded.instance_name === "greeter"
    # Path resolved against the package dir, not the process CWD.
    assert loaded.build === %{dockerfile: Path.join(pkg, "Dockerfile")}

    assert :ok = Dockd.delete_package(root, "greeter")
    assert Dockd.list_packages(root) === []
  end

  test "the env vars that used to name the packages root now name nothing", %{root: root} do
    assert {:ok, _} = Dockd.new_package(Path.join(root, "alpha"), "alpha")

    # Both ambient sources point somewhere that does not exist. If either were
    # still consulted, one of these would find alpha or blow up.
    assert Dockd.list_packages("/nonexistent/packages") === []
    assert Dockd.list_packages("/also/nonexistent") === []
    assert [%{name: "alpha"}] = Dockd.list_packages(root)
  end

  test "${VAR} resolves only from the host_env argument", %{root: root} do
    pkg = Path.join(root, "envpkg")
    File.mkdir_p!(pkg)

    File.write!(
      Path.join(pkg, "package.json"),
      ~s({"instance_name":"envpkg","image":"busybox","mounts":["${DOCKD_AMBIENT_PROBE}:/x"]})
    )

    # Defined in the real process environment...
    System.put_env("DOCKD_AMBIENT_PROBE", "/leaked/from/host")
    on_exit(fn -> System.delete_env("DOCKD_AMBIENT_PROBE") end)

    # ...and still invisible to the package, because host_env is empty.
    assert {:error, error} = Dockd.load_package_spec(root, "envpkg", %{})
    assert error.phase === :validate

    # Visible only when handed over deliberately, and only the value handed over.
    assert {:ok, spec} =
             Dockd.load_package_spec(root, "envpkg", %{"DOCKD_AMBIENT_PROBE" => "/passed/in"})

    # Still in string form here — Provisioner normalizes mounts later. What
    # matters is which value the interpolation picked up.
    assert spec.mounts === ["/passed/in:/x"]
  end

  test "DOCKER_HOST does not decide the daemon" do
    {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke")

    # DOCKER_HOST is set to a real-looking endpoint in setup. Passing no endpoint
    # must be a :validate error, not a silent fallback to it.
    for bad <- [nil, ""] do
      assert {:error, error} = Dockd.apply(spec, bad, false, %{}, System.tmp_dir!())
      assert error.phase === :validate
      assert error.message =~ "a Docker endpoint is required"
    end
  end

  test "delete_temp_files refuses a root it was not given properly" do
    for bad <- ["/", "", "relative/dir"] do
      assert {:error, %Dockd.Error{}} = Dockd.delete_temp_files(bad)
    end
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
