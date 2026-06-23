defmodule Mix.Tasks.Dockd.Instance.Inspect do
  @moduledoc """
  Pretty-prints the raw Docker inspect map for an instance.

  Wraps `Dockd.inspect/2`. Useful for digging into state that
  `%Dockd.Instance{}` does not surface - port bindings, network IPs,
  exit code, started timestamps, restart policy, etc.

  ## Usage

      mix dockd.instance.inspect NAME

  Accepts either the short name (`smoke`) or the prefixed Docker
  container name (`dockd-smoke`).
  """
  @shortdoc "Pretty-print the raw Docker inspect map"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [name] ->
        case Dockd.inspect(name) do
          {:ok, map} ->
            IO.write(inspect(map, pretty: true, limit: :infinity, width: 100) <> "\n")

          {:error, %Dockd.Error{} = err} ->
            Mix.raise(Exception.message(err))

          {:error, reason} ->
            Mix.raise("Failed to inspect instance: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("Usage: mix dockd.instance.inspect NAME")
    end
  end
end
