defmodule Mix.Tasks.Dockd.Tui do
  @moduledoc """
  Starts the Dockd terminal UI for an existing instance.

  ## Usage

      mix dockd.tui INSTANCE [opts]

  Run `mix dockd.tui --help` for the full option list.
  """

  @shortdoc "Start the dockd terminal UI"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> Dockd.Tui.CLI.run()
    |> case do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
