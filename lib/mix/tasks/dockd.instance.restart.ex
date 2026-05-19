defmodule Mix.Tasks.Dockd.Instance.Restart do
  @moduledoc """
  Stops, then starts, a dockd-managed instance.

  Wraps `Dockd.restart/2`. If the stop step fails the start step is
  skipped and the stop error is surfaced.

  ## Usage

      mix dockd.instance.restart NAME

  Accepts either the short name (`smoke`) or the prefixed Docker
  container name (`dockd-smoke`).
  """
  @shortdoc "Restart an instance"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [name] ->
        case Dockd.restart(name) do
          :ok -> Mix.shell().info("Restarted #{name}")
          {:error, %Dockd.Error{} = err} -> Mix.raise(Exception.message(err))
        end

      _ ->
        Mix.raise("Usage: mix dockd.instance.restart NAME")
    end
  end
end
