defmodule DockdCLI.Commands.Instance.Stop do
  @moduledoc """
  Stops a running dockd-managed instance, or every managed instance.

  Wraps `Dockd.stop/2`. Idempotent: stopping an already-stopped instance
  succeeds silently.

  With `--all`, stops every dockd-managed instance on the daemon. Stop
  is non-destructive and idempotent, so no confirmation is required.

  Accepts either the short name (`smoke`) or the prefixed Docker
  container name (`dockd-smoke`).
  """

  alias Dockd.Instance
  alias DockdCLI.Output
  alias DockdCLI.Json

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{all: true, name: name}, _opts) when is_binary(name) and name != "",
    do: {:error, "--all cannot be combined with a positional NAME"}

  def run(%{all: true}, opts), do: stop_all(opts)

  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.stop(name, opts) do
      :ok -> Output.info("Stopped #{name}")
      {:error, %Dockd.Error{} = err} -> {:error, Exception.message(err)}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance stop NAME | --all"}

  @spec run_json(map(), keyword()) :: :ok | {:error, term()}
  def run_json(%{all: true, name: name}, _opts) when is_binary(name) and name != "",
    do: {:error, "--all cannot be combined with a positional NAME"}

  def run_json(%{all: true}, opts), do: stop_all_json(opts)

  def run_json(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.stop(name, opts) do
      :ok -> Output.json(Json.action(name, "stopped"))
      {:error, err} -> {:error, err}
    end
  end

  def run_json(_args, _opts), do: {:error, "Usage: dockd instance stop NAME | --all"}

  defp stop_all(opts) do
    case Dockd.list(opts) do
      {:ok, []} -> Output.info("No dockd instances.")
      {:ok, instances} -> sweep(instances, opts)
      {:error, %Dockd.Error{} = err} -> {:error, Exception.message(err)}
    end
  end

  defp sweep(instances, opts) do
    results =
      Enum.map(instances, fn instance ->
        name = Instance.short_name(instance)

        case Dockd.stop(instance, opts) do
          :ok ->
            Output.info("Stopped #{name}")
            :ok

          {:error, %Dockd.Error{} = err} ->
            Output.error("Failed to stop #{name}: #{Exception.message(err)}")
            :error
        end
      end)

    failures = Enum.count(results, &(&1 == :error))

    if failures > 0 do
      {:error, "#{failures} of #{length(instances)} instance(s) failed to stop"}
    else
      :ok
    end
  end

  defp stop_all_json(opts) do
    case Dockd.list(opts) do
      {:ok, []} ->
        Output.json([])

      {:ok, instances} ->
        results = Enum.map(instances, &stop_one_json(&1, opts))
        Output.json(Enum.map(results, &elem(&1, 1)))
        failures = Enum.count(results, &(elem(&1, 0) == :error))

        if failures > 0,
          do: {:error, "#{failures} of #{length(instances)} instance(s) failed to stop"},
          else: :ok

      {:error, err} ->
        {:error, err}
    end
  end

  defp stop_one_json(instance, opts) do
    name = Instance.short_name(instance)

    case Dockd.stop(instance, opts) do
      :ok ->
        {:ok, %{name: name, action: "stopped", status: "ok"}}

      {:error, err} ->
        {:error, %{name: name, action: "stopped", status: "error", error: Exception.message(err)}}
    end
  end
end
