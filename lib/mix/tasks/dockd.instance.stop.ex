defmodule Mix.Tasks.Dockd.Instance.Stop do
  @moduledoc """
  Stops a running dockd-managed instance, or every managed instance.

  Wraps `Dockd.stop/2`. Idempotent: stopping an already-stopped instance
  succeeds silently.

  ## Usage

      mix dockd.instance.stop NAME
      mix dockd.instance.stop --all

  With `--all`, stops every dockd-managed instance on the daemon. Stop
  is non-destructive and idempotent, so no confirmation is required.

  Accepts either the short name (`smoke`) or the prefixed Docker
  container name (`dockd-smoke`).
  """
  @shortdoc "Stop a running instance"

  use Mix.Task

  alias Dockd.Instance

  @switches [all: :boolean]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown flags: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    cond do
      opts[:all] && args != [] ->
        Mix.raise("--all cannot be combined with a positional NAME")

      opts[:all] ->
        stop_all()

      match?([_], args) ->
        stop_one(hd(args))

      true ->
        Mix.raise("Usage: mix dockd.instance.stop NAME | --all")
    end
  end

  defp stop_one(name) do
    case Dockd.stop(name) do
      :ok -> Mix.shell().info("Stopped #{name}")
      {:error, %Dockd.Error{} = err} -> Mix.raise(Exception.message(err))
    end
  end

  defp stop_all do
    case Dockd.list() do
      {:ok, []} ->
        Mix.shell().info("No dockd instances.")

      {:ok, instances} ->
        sweep(instances)

      {:error, %Dockd.Error{} = err} ->
        Mix.raise(Exception.message(err))
    end
  end

  defp sweep(instances) do
    results =
      Enum.map(instances, fn instance ->
        name = Instance.short_name(instance)

        case Dockd.stop(instance) do
          :ok ->
            Mix.shell().info("Stopped #{name}")
            :ok

          {:error, %Dockd.Error{} = err} ->
            Mix.shell().error("Failed to stop #{name}: #{Exception.message(err)}")
            :error
        end
      end)

    failures = Enum.count(results, &(&1 == :error))

    if failures > 0 do
      Mix.raise("#{failures} of #{length(instances)} instance(s) failed to stop")
    end
  end
end
