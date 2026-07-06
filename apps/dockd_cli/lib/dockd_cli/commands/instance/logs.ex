defmodule DockdCLI.Commands.Instance.Logs do
  @moduledoc """
  Prints an instance's container logs (stdout + stderr).

  Wraps `Dockd.logs/2`. Writes the captured binary verbatim to stdout
  with no banner so it pipes cleanly into other tools.

  ## Usage

      dockd instance logs NAME [--tail N] [--timestamps]
                          [--since UNIX_TS] [--until UNIX_TS]
                          [--stdout-only] [--stderr-only]

  ## Examples

      dockd instance logs smoke
      dockd instance logs smoke --tail 100 --timestamps
      dockd instance logs smoke --stderr-only > smoke.err.log
  """

  alias DockdCLI.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{name: name} = args, opts) when is_binary(name) and name != "" do
    with {:ok, log_opts} <- build_log_opts(args) do
      case Dockd.logs(name, Keyword.merge(opts, log_opts)) do
        {:ok, binary} -> Output.write(binary)
        {:error, %Dockd.Error{} = err} -> {:error, Exception.message(err)}
        {:error, err} -> {:error, err}
      end
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance logs NAME [opts]"}

  @spec build_log_opts(map()) :: {:ok, keyword()} | {:error, binary()}
  def build_log_opts(args) do
    base =
      Enum.reduce([:tail, :timestamps, :since, :until], [], fn key, acc ->
        case Map.get(args, key) do
          nil -> acc
          value -> [{key, value} | acc]
        end
      end)

    cond do
      args[:stdout_only] && args[:stderr_only] ->
        {:error, "--stdout-only and --stderr-only are mutually exclusive"}

      args[:stdout_only] ->
        {:ok, base ++ [stdout: true, stderr: false]}

      args[:stderr_only] ->
        {:ok, base ++ [stdout: false, stderr: true]}

      true ->
        {:ok, base}
    end
  end
end
