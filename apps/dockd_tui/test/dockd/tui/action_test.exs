defmodule Dockd.Tui.ActionTest do
  use ExUnit.Case, async: true
  alias Dockd.Tui.Action
  alias Dockd.Tui.Data.Stub

  test "perform stop returns a done summary" do
    Stub.put(:stop, :ok)
    assert {:done, msg} = Action.perform(Stub, {:stop, "web"}, [])
    assert msg =~ "stopped web"
  end

  test "perform maps a Dockd.Error to an error summary" do
    Stub.put(:stop, {:error, %Dockd.Error{phase: :stop, message: "boom"}})
    assert {:error, msg} = Action.perform(Stub, {:stop, "web"}, [])
    assert msg =~ "stop" and msg =~ "boom"
  end

  test "perform info renders the info map" do
    Stub.put(:info, {:ok, %{temp_files: %{count: 3}}})
    assert {:done, msg} = Action.perform(Stub, {:info, %{}}, [])
    assert msg =~ "temp_files"
  end

  test "perform package_install summarizes installed names" do
    Stub.put(:install_package, {:ok, ["a", "b"]})
    assert {:done, msg} = Action.perform(Stub, {:package_install, %{source: "u"}}, [])
    assert msg =~ "2 package"
  end

  test "perform package_show lists installed package names" do
    Dockd.Tui.Data.Stub.put(
      :list_packages,
      {:ok,
       [
         %{name: "web", path: "/p/web", spec: {:ok, nil}},
         %{name: "api", path: "/p/api", spec: {:ok, nil}}
       ]}
    )

    assert {:done, msg} = Dockd.Tui.Action.perform(Dockd.Tui.Data.Stub, {:package_show, %{}}, [])
    assert msg =~ "web"
    assert msg =~ "api"
  end

  test "perform package_show reports when none are installed" do
    Dockd.Tui.Data.Stub.put(:list_packages, {:ok, []})
    assert {:done, msg} = Dockd.Tui.Action.perform(Dockd.Tui.Data.Stub, {:package_show, %{}}, [])
    assert msg =~ "No packages"
  end

  test "perform shell opens a window and reports success" do
    Dockd.Tui.Data.Stub.put(:open_shell_window, :ok)
    assert {:done, msg} = Dockd.Tui.Action.perform(Dockd.Tui.Data.Stub, {:shell, "web"}, [])
    assert msg =~ "web"
    assert msg =~ "window"
  end

  test "perform shell surfaces a launcher error" do
    Dockd.Tui.Data.Stub.put(:open_shell_window, {:error, "no terminal found"})
    assert {:error, msg} = Dockd.Tui.Action.perform(Dockd.Tui.Data.Stub, {:shell, "web"}, [])
    assert msg =~ "no terminal"
  end

  test "run sends started then done messages to the target" do
    Stub.put(:stop, :ok)
    Action.run(self(), Stub, {:stop, "web"}, [])
    assert_receive {:action, ref, :started, _label}
    assert_receive {:action, ^ref, :done, summary}
    assert summary =~ "stopped web"
  end

  defmodule RaisingData do
    @behaviour Dockd.Tui.Data
    @impl true
    def stop(_name, _opts), do: raise("boom from stop")
    @impl true
    def list(_o), do: {:ok, []}
    @impl true
    def logs(_n, _o), do: {:ok, ""}
    @impl true
    def inspect(_n, _o), do: {:ok, %{}}
    @impl true
    def start(_n, _o), do: :ok
    @impl true
    def restart(_n, _o), do: :ok
    @impl true
    def destroy(_n, _o), do: :ok
    @impl true
    def run(_v, _o), do: {:ok, %Dockd.Instance{id: "x", name: "x"}}
    @impl true
    def install_package(_s, _o), do: {:ok, []}
    @impl true
    def info(_o), do: {:ok, %{}}
    @impl true
    def list_packages(_o), do: {:ok, []}
    @impl true
    def open_shell_window(_i, _o), do: :ok
  end

  test "run reports an error when perform raises instead of hanging" do
    Dockd.Tui.Action.run(self(), RaisingData, {:stop, "web"}, [])
    assert_receive {:action, ref, :started, _}
    assert_receive {:action, ^ref, :error, message}
    assert message =~ "boom from stop"
  end
end
