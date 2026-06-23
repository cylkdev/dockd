defmodule Dockd.RPC.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = Dockd.RPC.Cluster.topology_supervisor([])
    Supervisor.start_link(children, strategy: :one_for_one, name: Dockd.RPC.Supervisor)
  end
end
