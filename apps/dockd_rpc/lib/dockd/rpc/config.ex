defmodule Dockd.RPC.Config do
  @moduledoc """
  Configuration helper for Dockd RPC and clustering.

  Each accessor takes a per-call `opts` keyword list and resolves a single
  setting from three sources, in order of precedence:

    1. an explicit value in `opts` under the setting's key;
    2. the environment variable `DOCKD_RPC_<KEY>` (the key, upper-cased);
    3. the application environment (`config :dockd_rpc, <key>: ...`).

  The first non-`nil` source is then resolved: a binary, integer, boolean, or
  list is taken as-is, a `{:system, "VAR"}` tuple is read from the environment,
  and any other shape resolves to `nil` and is replaced by the accessor default.
  """

  @app :dockd_rpc
  @service_name "dockd"

  @doc """
  Resolves the service name used as the default node filter.
  """
  @spec service_name(keyword()) :: binary() | integer()
  def service_name(opts) do
    opts
    |> get(:service_name)
    |> resolve()
    |> Kernel.||(@service_name)
  end

  @doc """
  Resolves the node filter used to select peers for clustering/RPC.
  """
  @spec node_filter(keyword()) :: binary() | integer()
  def node_filter(opts) do
    opts
    |> get(:node_filter)
    |> resolve()
    |> Kernel.||(service_name(opts))
  end

  @doc """
  Resolves the libcluster topology.
  """
  @spec cluster_topology(keyword()) :: list() | binary() | integer()
  def cluster_topology(opts) do
    opts
    |> get(:cluster_topology)
    |> resolve()
    |> Kernel.||([])
  end

  @doc """
  Resolves whether RPC routing is enabled.
  """
  @spec rpc(keyword()) :: boolean() | binary() | integer()
  def rpc(opts) do
    opts
    |> get(:rpc)
    |> resolve()
    |> truthy?()
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp resolve(entries) do
    entries
    |> List.wrap()
    |> Enum.reduce_while(nil, fn
      value, _acc when is_binary(value) -> {:halt, value}
      value, _acc when is_integer(value) -> {:halt, value}
      value, _acc when is_boolean(value) -> {:halt, value}
      value, _acc when is_list(value) -> {:halt, value}
      {:system, key}, _acc -> {:halt, System.get_env(key)}
      _acc, _ -> {:cont, nil}
    end)
  end

  defp get(opts, key) do
    Keyword.get(opts, key) ||
      key |> key_to_env() |> System.get_env() ||
      Application.get_env(@app, key)
  end

  defp key_to_env(key) do
    "#{String.upcase(to_string(@app))}_#{String.upcase(to_string(key))}"
  end
end
