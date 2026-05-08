defmodule Dockd.Application do
  @moduledoc """
  The OTP application entry point for `Dockd`.

  Dockd has no long-lived processes of its own — every workspace is short-lived and
  managed by the calling process — so `start/2` brings up an empty `:one_for_one`
  supervisor named `Dockd.Supervisor`. The supervisor exists so that future additions
  (background workers, telemetry handlers) have a defined parent without callers needing
  to restructure their app.

  ## Responsibilities

    - Start the application's supervision tree with no children today
    - Provide a stable `Dockd.Supervisor` name for any process that wants to attach a
      child later via `Supervisor.start_child/2`
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: Dockd.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
