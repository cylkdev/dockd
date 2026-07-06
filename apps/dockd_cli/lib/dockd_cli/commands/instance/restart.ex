defmodule DockdCLI.Commands.Instance.Restart do
  @moduledoc """
  Stops, then starts, a dockd-managed instance.

  Wraps `Dockd.restart/2`. If the stop step fails the start step is
  skipped and the stop error is surfaced.

  Accepts either the short name (`smoke`) or the prefixed Docker
  container name (`dockd-smoke`).
  """

  alias DockdCLI.Output
  alias DockdCLI.Json

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.restart(name, opts) do
      :ok -> Output.info("Restarted #{name}")
      {:error, %Dockd.Error{} = err} -> {:error, Exception.message(err)}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance restart NAME"}

  @spec run_json(map(), keyword()) :: :ok | {:error, term()}
  def run_json(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.restart(name, opts) do
      :ok -> Output.json(Json.action(name, "restarted"))
      {:error, err} -> {:error, err}
    end
  end

  def run_json(_args, _opts), do: {:error, "Usage: dockd instance restart NAME"}
end
