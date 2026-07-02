defmodule DockdCli.Main do
  @moduledoc "Entry point for the standalone `dockd` binary."
  use Application

  alias DockdCli.CLI
  alias DockdCli.Output

  # Burrito entrypoint wiring (only active in the `prod` release, see
  # apps/dockd_cli/mix.exs `mod/0`): Burrito requires an `Application` `:mod`
  # whose `start/2` runs the CLI and halts the VM — it does not invoke
  # `main/1` directly (see deps/burrito/README.md "Application Entry Point").
  # `start/2` fetches argv via `Burrito.Util.Args.argv/0` and delegates to
  # the pre-existing `main/1` below, which is otherwise unchanged.
  @impl Application
  def start(_type, _args) do
    main(Burrito.Util.Args.argv())
  end

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    ensure_started()

    case run(argv) do
      :ok -> System.halt(0)
      {:error, _} -> System.halt(1)
    end
  end

  # Verified against deps/optimus/lib/optimus.ex `Optimus.parse/2`:
  #   {:ok, ParseResult.t()}                  — top-level match, no subcommand
  #   {:ok, subcommand_path, ParseResult.t()}  — subcommand match
  #   {:error, [error]}                        — top-level parse error
  #   {:error, subcommand_path, [error]}       — subcommand parse error
  #   :version                                 — `--version` (handled by parse/2 itself)
  #   :help                                    — `--help` (handled by parse/2 itself)
  #   {:help, subcommand_path}                 — `help <subcommand>` (handled by parse/2 itself)
  @spec run([String.t()]) :: :ok | {:error, term()}
  def run(argv) do
    spec = CLI.spec()

    case Optimus.parse(spec, argv) do
      {:ok, path, parsed} ->
        report(CLI.dispatch({path, parsed}))

      {:ok, _parsed} ->
        # Top-level match with no subcommand: show help, succeed.
        IO.puts(Optimus.help(spec))
        :ok

      {:error, reasons} ->
        Enum.each(List.wrap(reasons), &Output.error/1)
        {:error, :usage}

      {:error, _path, reasons} ->
        Enum.each(List.wrap(reasons), &Output.error/1)
        {:error, :usage}

      :version ->
        IO.puts("#{spec.name} #{spec.version}")
        :ok

      :help ->
        IO.puts(Optimus.help(spec))
        :ok

      {:help, _subcommand_path} ->
        IO.puts(Optimus.help(spec))
        :ok
    end
  end

  defp report(:ok), do: :ok

  defp report({:error, %Dockd.Error{} = err}) do
    Output.error(Exception.message(err))
    {:error, err}
  end

  defp report({:error, msg}) when is_binary(msg) do
    Output.error(msg)
    {:error, msg}
  end

  defp report({:error, other}) do
    Output.error(inspect(other))
    {:error, other}
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:dockd)
    :ok
  end
end
