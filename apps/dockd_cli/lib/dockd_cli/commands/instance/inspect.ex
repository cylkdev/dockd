defmodule DockdCli.Commands.Instance.Inspect do
  @moduledoc """
  Pretty-prints the raw Docker inspect map for an instance.

  Wraps `Dockd.inspect/2`. Useful for digging into state that
  `%Dockd.Instance{}` does not surface - port bindings, network IPs,
  exit code, started timestamps, restart policy, etc.

  ## Usage

      dockd instance inspect NAME

  Accepts either the short name (`smoke`) or the prefixed Docker
  container name (`dockd-smoke`).
  """

  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.inspect(name, opts) do
      {:ok, map} -> Output.write(inspect(map, pretty: true, limit: :infinity, width: 100) <> "\n")
      {:error, %Dockd.Error{} = err} -> {:error, Exception.message(err)}
      {:error, err} -> {:error, err}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance inspect NAME"}
end
