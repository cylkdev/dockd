defmodule Dockd.Config do
  @moduledoc """
  Configuration helper for Dockd application.
  Provides convenience functions for accessing application configuration.
  """

  @app :dockd
  @service_name "dockd"

  def service_name, do: @service_name

  def node_filter(opts) do
    get(opts, :node_filter, @service_name)
  end

  def cluster_topology(opts) do
    get(opts, :cluster_topology, [])
  end

  def rpc_enabled?(opts) do
    get(opts, :rpc_enabled, false)
  end

  def temp_dir(opts) do
    get(opts, :temp_dir, Path.join(System.tmp_dir!(), "dockd"))
  end

  defp get(opts, key, default) do
    Keyword.get(opts, key) ||
      key |> key_to_env() |> System.get_env() ||
      Application.get_env(@app, key) ||
      default
  end

  defp key_to_env(key) do
    "#{String.upcase(to_string(@app))}_#{String.upcase(to_string(key))}"
  end
end
