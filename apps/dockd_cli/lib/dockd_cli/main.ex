defmodule DockdCLI.Main do
  @moduledoc """
  Burrito entry point for the standalone `dockd` binary.

  Only active in the `prod` release (see apps/dockd_cli/mix.exs `mod/0`).
  Burrito requires an `Application` `:mod` whose `start/2` runs the CLI and
  halts the VM (see deps/burrito/README.md "Application Entry Point"). All
  parsing/dispatch/reporting lives in `DockdCLI.CLI.run/1`.
  """
  use Application

  @impl Application
  def start(_type, _args) do
    case DockdCLI.CLI.run(Burrito.Util.Args.argv()) do
      :ok -> System.halt(0)
      {:error, _} -> System.halt(1)
    end
  end
end
