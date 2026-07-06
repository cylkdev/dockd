defmodule Dockd.Tui.Data do
  @moduledoc """
  The only seam between the dashboard and Docker. Every function the TUI needs
  is a callback here so views and dispatch can run against a stub with no
  daemon. `Dockd.Tui.Data.Live` is the production implementation; it delegates
  to the `Dockd.*` core API.
  """
  alias Dockd.Instance

  @callback list(keyword()) :: {:ok, [Instance.t()]} | {:error, term()}
  @callback logs(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback inspect(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop(binary(), keyword()) :: :ok | {:error, term()}
  @callback start(binary(), keyword()) :: :ok | {:error, term()}
  @callback restart(binary(), keyword()) :: :ok | {:error, term()}
  @callback destroy(binary(), keyword()) :: :ok | {:error, term()}
  @callback run(map(), keyword()) :: {:ok, Instance.t()} | {:error, term()}
  @callback install_package(binary(), keyword()) :: {:ok, [binary()]} | {:error, term()}
  @callback info(keyword()) :: {:ok, map()} | {:error, term()}
  @callback list_packages(keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback open_shell_window(Instance.t() | binary(), keyword()) :: :ok | {:error, term()}
end
