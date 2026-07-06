defmodule DockdCLI.Commands.Ssh.DialStdioScript.Install do
  @moduledoc """
  Deploys the dial-stdio wrapper script to a remote SSH host. Thin adapter
  over `Dockd.Ssh.resolve_source/1` and `Dockd.Ssh.install_script/3`. Reads
  `args.user_at_host` (required), `args.script_path`, `args.remote_path`,
  `args.identity`, `args.port`.
  """
  alias DockdCLI.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(args, _opts) do
    with {:ok, user_at_host} <- fetch_host(args),
         {:ok, {source, description}} <- Dockd.Ssh.resolve_source(Map.get(args, :script_path)) do
      case Dockd.Ssh.install_script(source, user_at_host, install_opts(args)) do
        {:ok, %{remote_path: remote_path}} ->
          Output.info("Installed #{description} → #{user_at_host}:#{remote_path}")

        {:error, message} ->
          {:error, message}
      end
    end
  end

  defp fetch_host(%{user_at_host: h}) when is_binary(h) and h != "", do: {:ok, h}
  defp fetch_host(_), do: {:error, "missing required USER_AT_HOST argument"}

  defp install_opts(args) do
    Enum.reduce([:remote_path, :identity, :port], [], fn key, acc ->
      case Map.get(args, key) do
        v when is_binary(v) and v != "" -> Keyword.put(acc, key, v)
        _ -> acc
      end
    end)
  end
end
