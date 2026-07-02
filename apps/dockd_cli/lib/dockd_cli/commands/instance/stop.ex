defmodule DockdCli.Commands.Instance.Stop do
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
  alias DockdCli.Output

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
end
