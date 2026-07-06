defmodule DockdCLI.Commands.Ssh.DialStdioScript.Generate do
  @moduledoc """
  Renders the bundled dial-stdio wrapper script to disk (mode 0o755). Thin
  adapter over `Dockd.Ssh.generate_script/2`. Reads `args.output_dir`
  (default cwd) and `args.force`.
  """
  alias DockdCLI.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(args, _opts) do
    dir = Map.get(args, :output_dir) || File.cwd!()
    force? = Map.get(args, :force, false)

    case Dockd.Ssh.generate_script(dir, force: force?) do
      {:ok, %{path: path, overwrote?: true}} ->
        Output.info("Generated #{path} (overwrote existing)")

      {:ok, %{path: path, overwrote?: false}} ->
        Output.info("Generated #{path}")

      {:error, msg} ->
        {:error, msg}
    end
  end
end
