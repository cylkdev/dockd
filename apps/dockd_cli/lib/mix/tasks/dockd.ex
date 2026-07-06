defmodule Mix.Tasks.Dockd do
  @shortdoc "Run a dockd command (same surface as the `dockd` binary)"
  @moduledoc """
  Thin forwarder to the shared CLI dispatch. `mix dockd <args>` runs the exact
  same parse + command path as the shipped `dockd` binary — there is no
  separate mix implementation.

      mix dockd instance list
      mix dockd instance run --image ubuntu:24.04 --name web
      mix dockd info

  Run `mix dockd --help` for the full command list.
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    case DockdCLI.CLI.run(argv) do
      :ok -> :ok
      {:error, _} -> exit({:shutdown, 1})
    end
  end
end
