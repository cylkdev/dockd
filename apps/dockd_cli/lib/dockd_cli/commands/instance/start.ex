defmodule DockdCLI.Commands.Instance.Start do
  @moduledoc """
  Starts a stopped dockd-managed instance, leaving it in place.

  Wraps `Dockd.start/2`. Idempotent: starting an already-running instance
  succeeds silently.

  Accepts either the short name (`smoke`) or the prefixed Docker
  container name (`dockd-smoke`).
  """

  alias DockdCLI.Output
  alias DockdCLI.Json

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.start(name, opts) do
      :ok -> Output.info("Started #{name}")
      {:error, %Dockd.Error{} = err} -> {:error, Exception.message(err)}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance start NAME"}

  @spec run_json(map(), keyword()) :: :ok | {:error, term()}
  def run_json(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.start(name, opts) do
      :ok -> Output.json(Json.action(name, "started"))
      {:error, err} -> {:error, err}
    end
  end

  def run_json(_args, _opts), do: {:error, "Usage: dockd instance start NAME"}
end
