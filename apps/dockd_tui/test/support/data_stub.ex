defmodule Dockd.Tui.Data.Stub do
  @moduledoc """
  Configurable `Dockd.Tui.Data` double for unit tests. Each callback returns
  the value stored under its name in the process dictionary (set with `put/2`),
  defaulting to a benign success so tests only configure what they assert on.
  """
  @behaviour Dockd.Tui.Data

  @spec put(atom(), term()) :: :ok
  def put(key, value), do: Process.put({__MODULE__, key}, value)

  defp get(key, default), do: Process.get({__MODULE__, key}, default)

  @impl true
  def list(_opts), do: get(:list, {:ok, []})
  @impl true
  def logs(_name, _opts), do: get(:logs, {:ok, ""})
  @impl true
  def inspect(_name, _opts), do: get(:inspect, {:ok, %{}})
  @impl true
  def stop(_name, _opts), do: get(:stop, :ok)
  @impl true
  def start(_name, _opts), do: get(:start, :ok)
  @impl true
  def restart(_name, _opts), do: get(:restart, :ok)
  @impl true
  def destroy(_name, _opts), do: get(:destroy, :ok)
  @impl true
  def run(_values, _opts), do: get(:run, {:ok, %Dockd.Instance{id: "stub", name: "stub"}})
  @impl true
  def install_package(_source, _opts), do: get(:install_package, {:ok, []})
  @impl true
  def info(_opts), do: get(:info, {:ok, %{}})
  @impl true
  def list_packages(_opts), do: get(:list_packages, {:ok, []})
  @impl true
  def open_shell_window(_instance_or_name, _opts), do: get(:open_shell_window, :ok)
end
