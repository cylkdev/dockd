defmodule Mix.Tasks.Dockd.Instance.Logs do
  @moduledoc """
  Prints an instance's container logs (stdout + stderr).

  Wraps `Dockd.logs/2`. Writes the captured binary verbatim to stdout
  with no banner so it pipes cleanly into other tools.

  ## Usage

      mix dockd.instance.logs NAME [--tail N] [--timestamps]
                          [--since UNIX_TS] [--until UNIX_TS]
                          [--stdout-only] [--stderr-only]

  ## Examples

      mix dockd.instance.logs smoke
      mix dockd.instance.logs smoke --tail 100 --timestamps
      mix dockd.instance.logs smoke --stderr-only > smoke.err.log
  """
  @shortdoc "Print an instance's container logs"

  use Mix.Task

  @switches [
    tail: :integer,
    timestamps: :boolean,
    since: :integer,
    until: :integer,
    stdout_only: :boolean,
    stderr_only: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown flags: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    case args do
      [name] -> fetch(name, opts)
      _ -> Mix.raise("Usage: mix dockd.instance.logs NAME [opts]")
    end
  end

  defp fetch(name, opts) do
    log_opts = build_log_opts(opts)

    case Dockd.logs(name, log_opts) do
      {:ok, binary} ->
        IO.write(binary)

      {:error, %Dockd.Error{} = err} ->
        Mix.raise(Exception.message(err))

      {:error, reason} ->
        Mix.raise("Failed to fetch logs: #{inspect(reason)}")
    end
  end

  defp build_log_opts(opts) do
    base =
      opts
      |> Keyword.take([:tail, :timestamps, :since, :until])

    cond do
      opts[:stdout_only] && opts[:stderr_only] ->
        Mix.raise("--stdout-only and --stderr-only are mutually exclusive")

      opts[:stdout_only] ->
        base ++ [stdout: true, stderr: false]

      opts[:stderr_only] ->
        base ++ [stdout: false, stderr: true]

      true ->
        base
    end
  end
end
