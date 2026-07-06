defmodule DockdCLI.Commands.Tui do
  @moduledoc """
  Launches the dockd dashboard TUI (`dockd tui`) and blocks until it exits.

  Execution logic lives in `Dockd.Tui.Dashboard`; this module only starts it
  with the resolved Docker connection `opts` and waits. `:launcher`/`:awaiter`
  funs are injectable for tests.
  """

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(_args, opts) do
    {launcher, opts} = Keyword.pop(opts, :launcher, &default_launch/1)
    {awaiter, conn_opts} = Keyword.pop(opts, :awaiter, &await/1)

    case launcher.(opts: conn_opts) do
      {:ok, pid} ->
        awaiter.(pid)
        :ok

      {:error, reason} ->
        {:error, "failed to start dockd TUI: #{inspect(reason)}"}
    end
  end

  defp default_launch(dashboard_opts) do
    with {:ok, _apps} <- Application.ensure_all_started(:dockd_tui) do
      Dockd.Tui.Dashboard.start_link(dashboard_opts)
    end
  end

  defp await(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp await(_non_pid), do: :ok
end
