defmodule Dockd.RPC.Cluster do
  @moduledoc false

  def list_nodes do
    [:erlang.node() | :erlang.nodes()]
  end

  def node_equal?(node \\ node(), string) do
    to_string(node) =~ string
  end

  def filter_nodes(node_list \\ list_nodes(), filter_match) do
    Enum.filter(node_list, &(to_string(&1) =~ filter_match))
  end

  def topology_supervisor(opts) do
    [{Cluster.Supervisor, [Dockd.Config.cluster_topology(opts), opts]}]
  end
end
