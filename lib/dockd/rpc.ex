defmodule Dockd.RPC do
  @moduledoc """
  Cluster-aware RPC dispatch used by the `Dockd` public-API forwarders.

  Every function in `Dockd` calls into this module to either run the
  operation locally or hand it off to a peer node. The candidate node
  set is resolved by `Dockd.Config.node_filter/1`, narrowed by the
  `:dockd` key in caller opts. When clustering is disabled or no
  matching peer is reachable, the call runs in-process.
  """

  @logger_prefix "Dockd.RPC"

  @default_timeout :timer.seconds(10)

  def dispatch(node_filter, module, fun, args, opts \\ []) do
    if Dockd.Config.rpc_enabled?(opts) and like_fully_qualified_node?(node_filter) do
      call(node_filter, module, fun, args, opts)
    else
      call_on_random_node(node_filter, module, fun, args, opts)
    end
  end

  defp like_fully_qualified_node?(:nonode@nohost), do: false
  defp like_fully_qualified_node?("nonode@nohost"), do: false

  defp like_fully_qualified_node?(str) when is_binary(str), do: String.contains?(str, "@")

  defp like_fully_qualified_node?(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> like_fully_qualified_node?()
  end

  defp like_fully_qualified_node?(_), do: false

  @spec call_on_random_node(
          node_filter :: binary(),
          module :: atom(),
          fun :: atom(),
          args :: list(),
          opts :: keyword()
        ) :: :ok | :error | {:ok, any()} | {:error, any()}
  @spec call_on_random_node(
          node_filter :: binary(),
          module :: atom(),
          fun :: atom(),
          args :: list()
        ) :: :ok | :error | {:ok, any()} | {:error, any()}
  def call_on_random_node(node_filter, module, fun, args, opts \\ []) do
    if eligible_for_rpc?(node_filter, opts) do
      Dockd.Log.debug(
        @logger_prefix,
        "Calling #{inspect(module)}.#{fun}/#{length(args)} on random node in cluster matching filter #{node_filter}"
      )

      case Dockd.RPC.Cluster.filter_nodes(node_filter) do
        [] -> handle_no_nodes_found(node_filter, module, fun, args, opts)
        node_list -> node_list |> Enum.random() |> call(module, fun, args, opts)
      end
    else
      Dockd.Log.debug(@logger_prefix, "Calling #{inspect(module)}.#{fun}/#{length(args)} locally")
      apply_inline(module, fun, args)
    end
  end

  defp handle_no_nodes_found(node_filter, module, fun, args, opts) do
    Dockd.Log.warning(
      @logger_prefix,
      "No nodes in cluster found to scrape based on filter #{inspect(node_filter)}, retrying in 5 seconds..."
    )

    5 |> :timer.seconds() |> Process.sleep()

    if Keyword.get(opts, :retry?, true) do
      Dockd.Log.debug(
        @logger_prefix,
        "Retrying call to #{inspect(module)}.#{fun}/#{length(args)} on random node in cluster matching filter #{node_filter}"
      )

      call_on_random_node(node_filter, module, fun, args, opts)
    else
      {:error,
       ErrorMessage.service_unavailable("no nodes in cluster found with that filter", %{
         node_filter: node_filter
       })}
    end
  end

  @doc """
  Evaluates `apply(module, fun, args)` on `node` and returns the corresponding result in a status tuple.

  The `timeout` option is an integer representing the timeout in milliseconds or the atom `:infinity` which prevents
  the operation from ever timing out.
  """
  @spec call(
          node :: node(),
          module :: atom(),
          fun :: atom(),
          args :: list(),
          opts :: keyword()
        ) :: :ok | :error | {:ok, any()} | {:error, any()}
  @spec call(
          node :: node(),
          module :: atom(),
          fun :: atom(),
          args :: list()
        ) :: :ok | :error | {:ok, any()} | {:error, any()}
  def call(node, module, fun, args, opts \\ []) do
    {_duration, response} =
      :timer.tc(fn ->
        if eligible_for_rpc?(node, opts) do
          try do
            Dockd.Log.debug(
              @logger_prefix,
              "Calling #{inspect(module)}.#{fun}/#{length(args)} on node #{node}"
            )

            :erpc.call(node, module, fun, args, opts[:timeout] || @default_timeout)
          rescue
            e in ErlangError ->
              {:error, translate_erpc_error(e)}

            e ->
              {:error,
               ErrorMessage.service_unavailable("rpc: unavailable", details: %{exception: e})}
          end
        else
          Dockd.Log.debug(
            @logger_prefix,
            "Calling #{inspect(module)}.#{fun}/#{length(args)} locally"
          )

          apply_inline(module, fun, args)
        end
      end)

    handle_response(response)
  end

  @doc """
  Evaluates `apply(module, fun, args)` on `node`. Returns immediately after the cast request has been sent.
  No response is delivered to the calling process.

  Any failures besides bad arguments are silently ignored.
  """
  @spec cast(node(), module(), atom(), [term], keyword()) :: :ok | {:error, any}
  @spec cast(node(), module(), atom(), [term]) :: :ok | {:error, any}
  def cast(node, module, fun, args, opts \\ []) do
    response =
      if eligible_for_rpc?(node, opts) do
        try do
          Dockd.Log.debug(
            @logger_prefix,
            "Casting #{inspect(module)}.#{fun}/#{length(args)} on node #{node}"
          )

          :erpc.cast(node, module, fun, args)
        rescue
          e in ErlangError ->
            {:error, translate_erpc_error(e)}

          e ->
            {:error,
             ErrorMessage.service_unavailable("rpc: unavailable", details: %{exception: e})}
        end
      else
        Dockd.Log.debug(
          @logger_prefix,
          "Casting #{inspect(module)}.#{fun}/#{length(args)} locally"
        )

        apply_async(module, fun, args, opts)
      end

    handle_response(response)
  end

  defp apply_async(module, fun, args, opts) do
    async_module = Keyword.get(opts, :async_module, Task)

    _ =
      async_module.async(fn ->
        module
        |> apply(fun, args)
        |> handle_response()
      end)

    :ok
  end

  defp apply_inline(module, fun, args) do
    module
    |> apply(fun, args)
    |> handle_response()
  end

  defp eligible_for_rpc?(:nonode@nohost, _opts), do: false
  defp eligible_for_rpc?("nonode@nohost", _opts), do: false

  defp eligible_for_rpc?(node, opts) do
    Dockd.Config.rpc_enabled?(opts) and to_string(node) != to_string(node())
  end

  defp translate_erpc_error(e) do
    case e do
      %ErlangError{original: {:erpc, :badarg}} = e ->
        ErrorMessage.bad_request("rpc: bad request", %{exception: e})

      %ErlangError{original: {:erpc, :noconnection}} = e ->
        ErrorMessage.service_unavailable("rpc: noconnection", %{exception: e})

      %ErlangError{original: {:erpc, :timeout}} = e ->
        ErrorMessage.request_timeout("rpc: timeout", %{exception: e})

      e ->
        ErrorMessage.service_unavailable("rpc: unavailable", %{exception: e})
    end
  end

  defp handle_response(:ok), do: :ok
  defp handle_response(:error), do: :error
  defp handle_response({:ok, _} = response), do: response
  defp handle_response({:error, _} = error), do: error
  defp handle_response(term), do: {:ok, term}
end
