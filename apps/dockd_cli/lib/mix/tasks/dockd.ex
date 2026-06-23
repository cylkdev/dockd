defmodule Mix.Tasks.Dockd do
  @moduledoc """
  Usage entry point for the `mix dockd.*` task family.

  Running `mix dockd` with no subcommand prints the list of available
  tasks and their one-line descriptions, then exits. It performs no
  side effects of its own - every actual operation lives in a
  dedicated subtask.

  ## Subtasks

      mix dockd.instance.run      - Provision and start a Docker instance
      mix dockd.instance.list     - List dockd-managed instances
      mix dockd.instance.start    - Start a stopped instance
      mix dockd.instance.stop     - Stop a running instance
      mix dockd.instance.restart  - Restart an instance
      mix dockd.instance.destroy  - Stop and remove an instance (or all of them)
      mix dockd.instance.logs     - Print an instance's container logs
      mix dockd.instance.inspect  - Pretty-print the raw Docker inspect map
      mix dockd.info              - Show aggregate dockd state (temp files, etc.)
      mix dockd.claude_code.install - Generate Claude Code packages
      mix dockd.package.install   - Install packages from a remote source
      mix dockd.package.show      - List installed packages
      mix dockd.tui               - Start the terminal UI for an instance

  Run `mix help dockd.<task>` for full usage on any subtask.
  """
  @shortdoc "List dockd mix tasks"

  use Mix.Task

  @subtasks [
    {"mix dockd.instance.run", "Provision and start a Docker instance"},
    {"mix dockd.instance.list", "List dockd-managed instances"},
    {"mix dockd.instance.start NAME", "Start a stopped instance"},
    {"mix dockd.instance.stop NAME", "Stop a running instance"},
    {"mix dockd.instance.restart NAME", "Restart an instance"},
    {"mix dockd.instance.destroy NAME|--all", "Stop and remove an instance"},
    {"mix dockd.instance.logs NAME", "Print an instance's container logs"},
    {"mix dockd.instance.inspect NAME", "Pretty-print the raw Docker inspect map"},
    {"mix dockd.info", "Show aggregate dockd state"},
    {"mix dockd.claude_code.install", "Generate Claude Code packages"},
    {"mix dockd.package.install <source>", "Install packages from a remote source"},
    {"mix dockd.package.show", "List installed packages"},
    {"mix dockd.tui NAME", "Start the terminal UI for an instance"}
  ]

  @impl Mix.Task
  def run(_args) do
    width =
      @subtasks
      |> Enum.map(fn {invocation, _} -> String.length(invocation) end)
      |> Enum.max()

    Mix.shell().info("Usage: mix dockd.<task> [args]")
    Mix.shell().info("")
    Mix.shell().info("Available tasks:")

    for {invocation, summary} <- @subtasks do
      padded = String.pad_trailing(invocation, width)
      Mix.shell().info("  #{padded}  #{summary}")
    end

    Mix.shell().info("")
    Mix.shell().info("Run `mix help dockd.<task>` for full usage on any subtask.")
    :ok
  end
end
