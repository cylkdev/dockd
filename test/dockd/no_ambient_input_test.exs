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

    :ok
  end

  test "a spec map is applied exactly as written, with nothing filled in" do
    map = %{
      instance_name: "greeter",
      image: "busybox:1.37.0",
      shell: "/bin/sh",
      build: %{dockerfile: "/abs/pkg/Dockerfile"}
    }

    assert {:ok, spec} = Dockd.Spec.from_map(map)

    assert spec.instance_name === "greeter"
    assert spec.image === "busybox:1.37.0"
    # Carried through verbatim: no packages root, no CWD, no home directory took
    # part in resolving this path.
    assert spec.build === %{dockerfile: "/abs/pkg/Dockerfile"}
  end

  # There is no package loader left to consult a root, which is the strongest
  # form this guarantee can take: the read cannot happen because the code that
  # would do it does not exist.
  test "dockd exposes no function that reads a spec from disk" do
    exports = Dockd.__info__(:functions) ++ Dockd.Spec.__info__(:functions)

    for {name, _arity} <- exports do
      refute to_string(name) =~ ~r/package|from_file|load/,
             "#{name} looks like it reads a spec from disk"
    end
  end

  test "${VAR} is not substituted, so nothing can leak in through a spec map" do
    System.put_env("DOCKD_AMBIENT_PROBE", "/leaked/from/host")
    on_exit(fn -> System.delete_env("DOCKD_AMBIENT_PROBE") end)

    assert {:ok, spec} =
             Dockd.Spec.from_map(%{
               instance_name: "envpkg",
               image: "busybox:1.37.0",
               mounts: ["${DOCKD_AMBIENT_PROBE}:/x"]
             })

    # Left exactly as written. The caller interpolates, so the host value is
    # never reachable by accident.
    assert spec.mounts === ["${DOCKD_AMBIENT_PROBE}:/x"]
  end

  test ":env resolves only from the host_env argument" do
    System.put_env("DOCKD_AMBIENT_PROBE", "/leaked/from/host")
    on_exit(fn -> System.delete_env("DOCKD_AMBIENT_PROBE") end)

    {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke", env: ["DOCKD_AMBIENT_PROBE"])

    # Defined in the real process environment, and still invisible: host_env is
    # empty, so there is nothing to resolve against.
    assert {:error, error} = Dockd.Provisioner.resolve_env(spec, %{})
    assert error.details.phase === :validate
    assert error.message =~ "absent from host_env"

    # Visible only when handed over deliberately, and only the value handed over.
    assert {:ok, ["DOCKD_AMBIENT_PROBE=/passed/in"]} =
             Dockd.Provisioner.resolve_env(spec, %{"DOCKD_AMBIENT_PROBE" => "/passed/in"})
  end

  test "DOCKER_HOST does not decide the daemon" do
    {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke")

    # DOCKER_HOST is set to a real-looking endpoint in setup. Passing no endpoint
    # must be a :validate error, not a silent fallback to it.
    for bad <- [nil, ""] do
      assert {:error, error} = Dockd.apply(spec, bad, false, %{}, System.tmp_dir!())
      assert error.details.phase === :validate
      assert error.message =~ "a Docker endpoint is required"
    end
  end

  test "delete_temp_files refuses a root it was not given properly" do
    for bad <- ["/", "", "relative/dir"] do
      assert {:error, %ErrorMessage{}} = Dockd.delete_temp_files(bad)
    end
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
