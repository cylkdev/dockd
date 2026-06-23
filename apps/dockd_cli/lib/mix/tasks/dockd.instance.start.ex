defmodule Mix.Tasks.Dockd.Instance.Start do
  @moduledoc """
  Starts a stopped dockd-managed instance, leaving it in place.

  Wraps `Dockd.start/2`. Idempotent: starting an already-running instance
  succeeds silently.

  ## Usage

      mix dockd.instance.start NAME

  Accepts either the short name (`smoke`) or the prefixed Docker
  container name (`dockd-smoke`).
  """
  @shortdoc "Start a stopped instance"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [name] ->
        case Dockd.start(name) do
          :ok -> Mix.shell().info("Started #{name}")
          {:error, %Dockd.Error{} = err} -> Mix.raise(Exception.message(err))
        end

      _ ->
        Mix.raise("Usage: mix dockd.instance.start NAME")
    end
  end
end
