defmodule DockdCLI.Commands.Instance.Shell do
  @moduledoc """
  `dockd instance shell --name NAME` — open a real interactive shell in a new OS
  window (`docker exec -it`). Thin adapter over `Dockd.Shell`. `--print` emits the
  `docker exec` command instead of opening a window (headless/CI). `--shell`
  overrides the program.
  """
  alias Dockd.Instance
  alias DockdCLI.Output

  @spec run(map(), keyword()) :: :ok | {:error, binary()}
  def run(%{name: name} = args, opts) when is_binary(name) and name != "" do
    with {:ok, instance} <- fetch(name, opts),
         :ok <- ensure_running(instance) do
      program = shell_override(args)

      if args[:print] do
        Output.write(Dockd.Shell.connect_command(instance, program) <> "\n")
        :ok
      else
        case Dockd.Shell.open_window(instance, shell: program) do
          :ok ->
            Output.notice(
              "dockd: opened a shell for #{Instance.short_name(instance)} in a new window"
            )

          {:error, message} ->
            {:error, message}
        end
      end
    end
  end

  def run(_args, _opts),
    do: {:error, "Usage: dockd instance shell --name NAME (see: dockd instance list)"}

  @spec shell_override(map()) :: binary() | nil
  def shell_override(%{shell: s}) when is_binary(s) and s != "", do: s
  def shell_override(_), do: nil

  @spec ensure_running(Instance.t()) :: :ok | {:error, binary()}
  def ensure_running(%Instance{running?: true}), do: :ok
  def ensure_running(%Instance{name: name}), do: {:error, "Instance #{name} is not running"}

  defp fetch(name, opts) do
    case Dockd.get(name, opts) do
      {:ok, %Instance{} = instance} -> {:ok, instance}
      {:error, _} -> {:error, "No instance named #{name}"}
    end
  end
end
