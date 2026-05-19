defmodule Mix.Tasks.Dockd.Instance.Destroy do
  @moduledoc """
  Stops and removes a dockd-managed instance, or every managed instance.

  Wraps `Dockd.destroy/2`. Idempotent: destroying an already-removed
  instance succeeds silently.

  ## Usage

      mix dockd.instance.destroy NAME
      mix dockd.instance.destroy --all [--force]

  With `--all`, prompts for confirmation before removing every
  dockd-managed instance on the daemon. Pass `--force` to skip the
  prompt - useful in scripts.

  ## Examples

      mix dockd.instance.destroy smoke
      mix dockd.instance.destroy --all
      mix dockd.instance.destroy --all --force
  """
  @shortdoc "Stop and remove an instance"

  use Mix.Task

  alias Dockd.Instance

  @switches [all: :boolean, force: :boolean]

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
        destroy_all(opts[:force] || false)

      match?([_], args) ->
        destroy_one(hd(args))

      true ->
        Mix.raise("Usage: mix dockd.instance.destroy NAME | --all [--force]")
    end
  end

  defp destroy_one(name) do
    case Dockd.destroy(name) do
      :ok -> Mix.shell().info("Destroyed #{name}")
      {:error, %Dockd.Error{} = err} -> Mix.raise(Exception.message(err))
    end
  end

  defp destroy_all(force?) do
    case Dockd.list() do
      {:ok, []} ->
        Mix.shell().info("No dockd instances.")

      {:ok, instances} ->
        if force? or confirm_destroy_all(instances) do
          sweep(instances)
        else
          Mix.shell().info("Aborted.")
        end

      {:error, %Dockd.Error{} = err} ->
        Mix.raise(Exception.message(err))
    end
  end

  defp confirm_destroy_all(instances) do
    Mix.shell().yes?("Destroy #{length(instances)} dockd instance(s)?")
  end

  defp sweep(instances) do
    results =
      Enum.map(instances, fn instance ->
        name = Instance.short_name(instance)

        case Dockd.destroy(instance) do
          :ok ->
            Mix.shell().info("Destroyed #{name}")
            :ok

          {:error, %Dockd.Error{} = err} ->
            Mix.shell().error("Failed to destroy #{name}: #{Exception.message(err)}")
            :error
        end
      end)

    failures = Enum.count(results, &(&1 == :error))

    if failures > 0 do
      Mix.raise("#{failures} of #{length(instances)} instance(s) failed to destroy")
    end
  end
end
