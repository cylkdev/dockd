defmodule Dockd.Tui.CLI do
  @moduledoc """
  Command-line entry point for starting the Dockd terminal UI.

  The CLI opens a raw PTY-backed shell inside an existing dockd-managed
  container and blocks until the TUI process exits.
  """

  @usage """
  Usage: dockd_tui INSTANCE [opts]

  Options:
    --shell SHELL          Shell binary to run inside the instance (default: /bin/sh)
    --socket PATH          Docker socket path
    --host HOST            Docker host
    --api-version VERSION  Docker API version
    --platform PLATFORM    Docker platform
    --network NAME         Docker network, may be given more than once
    --network-mode MODE    Docker network mode
    --help                 Print this help

  Controls:
    Ctrl-\\                 Close the TUI
  """

  @switches [
    shell: :string,
    socket: :string,
    host: :string,
    api_version: :string,
    platform: :string,
    network: :keep,
    network_mode: :string,
    help: :boolean
  ]

  @aliases [
    h: :help
  ]

  @doc """
  Escript entry point.
  """
  @spec main([binary()]) :: no_return()
  def main(args) do
    args
    |> run()
    |> System.halt()
  end

  @doc """
  Parses CLI arguments, opens the TUI, and blocks until it exits.

  Options are primarily for tests:

    * `:starter` - function used to start the shell TUI.
    * `:await` - function used to wait for the TUI process.
    * `:io` - module used for output.
    * `:app_starter` - function used to start `:dockd_tui`.
  """
  @spec run([binary()], keyword()) :: non_neg_integer()
  def run(args, opts \\ []) do
    io = Keyword.get(opts, :io, IO)

    case parse(args) do
      {:help, usage} ->
        io.puts(usage)
        0

      {:ok, instance, shell_opts} ->
        start(instance, shell_opts, opts)

      {:error, message} ->
        io.puts(:stderr, message <> "\n\n" <> usage())
        1
    end
  end

  @doc """
  Parses CLI args into a target instance and `Dockd.ShellTui` options.
  """
  @spec parse([binary()]) :: {:ok, binary(), keyword()} | {:help, binary()} | {:error, binary()}
  def parse(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        {:help, usage()}

      invalid != [] ->
        {:error, "invalid option: #{format_invalid(invalid)}"}

      positional == [] ->
        {:error, "INSTANCE is required"}

      match?([_instance], positional) ->
        [instance] = positional
        {:ok, instance, shell_opts(opts)}

      true ->
        [_instance | extra] = positional
        {:error, "unexpected arguments: #{Enum.join(extra, " ")}"}
    end
  end

  @doc """
  Returns the CLI usage text.
  """
  @spec usage() :: binary()
  def usage, do: @usage

  defp start(instance, shell_opts, opts) do
    app_starter = Keyword.get(opts, :app_starter, &Application.ensure_all_started/1)
    starter = Keyword.get(opts, :starter, &Dockd.ShellTui.open/2)
    await = Keyword.get(opts, :await, &await/1)
    io = Keyword.get(opts, :io, IO)

    with {:ok, _apps} <- app_starter.(:dockd_tui),
         {:ok, pid} <- starter.(instance, shell_opts) do
      await.(pid)
      0
    else
      {:error, reason} ->
        io.puts(:stderr, "failed to start dockd TUI: #{inspect(reason)}")
        1
    end
  end

  defp await(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp shell_opts(opts) do
    opts
    |> Keyword.take([:socket, :host, :api_version, :platform, :network_mode])
    |> maybe_put_shell(opts[:shell])
    |> maybe_put_networks(Keyword.get_values(opts, :network))
  end

  defp maybe_put_shell(opts, nil), do: opts
  defp maybe_put_shell(opts, shell), do: Keyword.put(opts, :shell, [shell])

  defp maybe_put_networks(opts, []), do: opts
  defp maybe_put_networks(opts, networks), do: Keyword.put(opts, :networks, networks)

  defp format_invalid([{flag, value} | _]) do
    Enum.join([to_string(flag), value], " ")
  end
end
