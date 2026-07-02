defmodule DockdCli.Commands.Instance.Destroy do
  @moduledoc """
  Stops and removes a dockd-managed instance, or every managed instance.

  Wraps `Dockd.destroy/2`. Idempotent: destroying an already-removed
  instance succeeds silently.

  With `--all`, prompts for confirmation before removing every
  dockd-managed instance on the daemon. Pass `--force` to skip the
  prompt - useful in scripts.

  Accepts either the short name (`smoke`) or the prefixed Docker
  container name (`dockd-smoke`).
  """

  alias Dockd.Instance
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{all: true, name: name}, _opts) when is_binary(name) and name != "",
    do: {:error, "--all cannot be combined with a positional NAME"}

  def run(%{all: true} = args, opts), do: destroy_all(Map.get(args, :force, false), opts)

  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.destroy(name, opts) do
      :ok -> Output.info("Destroyed #{name}")
      {:error, %Dockd.Error{} = err} -> {:error, Exception.message(err)}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance destroy NAME | --all [--force]"}

  defp destroy_all(force?, opts) do
    case Dockd.list(opts) do
      {:ok, []} ->
        Output.info("No dockd instances.")

      {:ok, instances} ->
        if force? or confirm_destroy_all(instances) do
          sweep(instances, opts)
        else
          Output.info("Aborted.")
        end

      {:error, %Dockd.Error{} = err} ->
        {:error, Exception.message(err)}
    end
  end

  defp confirm_destroy_all(instances) do
    prompt = "Destroy #{length(instances)} dockd instance(s)? [Yn] "

    case IO.gets(prompt) do
      :eof -> false
      {:error, _} -> false
      answer -> String.trim(answer) in ["", "y", "Y", "yes", "Yes"]
    end
  end

  defp sweep(instances, opts) do
    results =
      Enum.map(instances, fn instance ->
        name = Instance.short_name(instance)

        case Dockd.destroy(instance, opts) do
          :ok ->
            Output.info("Destroyed #{name}")
            :ok

          {:error, %Dockd.Error{} = err} ->
            Output.error("Failed to destroy #{name}: #{Exception.message(err)}")
            :error
        end
      end)

    failures = Enum.count(results, &(&1 == :error))

    if failures > 0 do
      {:error, "#{failures} of #{length(instances)} instance(s) failed to destroy"}
    else
      :ok
    end
  end
end
