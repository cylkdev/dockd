defmodule Dockd.RPC.Cluster do
  @moduledoc false
  # Internal cluster helpers: node discovery and libcluster topology
  # supervision. Used by `Dockd.RPC` to resolve which nodes match a filter
  # before dispatching a remote call.

  @spec list_nodes() :: [node()]
  def list_nodes do
    [:erlang.node() | :erlang.nodes()]
  end

  @spec node_equal?(node() | binary(), binary()) :: boolean()
  @spec node_equal?(binary()) :: boolean()
  def node_equal?(node \\ node(), string) do
    to_string(node) =~ string
  end

  @spec filter_nodes([node()], binary()) :: [node()]
  @spec filter_nodes(binary()) :: [node()]
  def filter_nodes(node_list \\ list_nodes(), filter_match) do
    Enum.filter(node_list, &(to_string(&1) =~ filter_match))
  end

  @spec topology_supervisor(keyword()) :: [{module(), list()}]
  def topology_supervisor(opts) do
    case Dockd.RPC.Config.cluster_topology(opts) do
      [] -> []
      topology -> [{Cluster.Supervisor, [topology, opts]}]
    end
  end
end
