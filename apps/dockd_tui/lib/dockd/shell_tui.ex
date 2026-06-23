defmodule Dockd.ShellTui do
  @moduledoc """
  Bridges `Dockd.Tui` to a streaming PTY-attached shell inside a
  container, suitable for driving interactive programs running inside
  the container.

  `init/1` opens a PTY-backed exec session via
  `Docker.Terminal.Controller.open/2`. The bridge process owns the
  `Docker.Streaming.Session.t/0` and receives its
  `{:docker_stream, _, :data, chunk}` messages — each chunk is
  appended to the TUI verbatim (after ANSI stripping). The TUI's
  `:on_input` callback casts raw byte sequences back to the bridge,
  which writes them to the session with
  `Docker.Streaming.Session.send/2`.
  """

  use GenServer

  alias Dockd.Instance
  alias Dockd.Spec
  alias Dockd.Tui
  alias Docker.Streaming.Session
  alias Docker.Terminal.Controller

  @docker_opt_keys [:socket, :host, :api_version, :platform, :networks, :network_mode]

  @doc """
  Starts a shell-bridge process connecting a `Dockd.Tui` to a PTY-backed exec
  session inside the target instance.

  `instance_or_ref` is a `%Dockd.Instance{}` or a workspace reference (which is
  prefixed before use). Options:

    * `:shell` — the command to exec, as an argv list. Defaults to `["/bin/sh"]`.
    * Docker connection options (`:socket`, `:host`, `:api_version`,
      `:platform`, `:networks`, `:network_mode`) are forwarded to the exec
      session.
    * Any remaining options are passed through to `Dockd.Tui.start_link/1`
      (the bridge injects its own `:on_input` callback, so passthrough mode is
      always used).

  Returns a `GenServer.on_start/0`. The bridge traps exits and links both the
  TUI and the streaming session; when either ends, the bridge stops and tears
  the other down.
  """
  @spec open(Instance.t() | binary(), keyword()) :: GenServer.on_start()
  def open(instance_or_ref, opts \\ []) do
    GenServer.start_link(__MODULE__, {instance_or_ref, opts})
  end

  @doc """
  Stops the shell bridge.

  Terminating the bridge runs `terminate/2`, which stops the TUI and closes the
  streaming session. Returns `:ok`.
  """
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init({instance_or_ref, opts}) do
    Process.flag(:trap_exit, true)

    {shell_cmd, opts} = Keyword.pop(opts, :shell, ["/bin/sh"])
    {docker_opts, tui_opts0} = Keyword.split(opts, @docker_opt_keys)

    ref = resolve_ref(instance_or_ref)
    parent = self()
    tui_opts = Keyword.put(tui_opts0, :on_input, &cast_input(parent, &1))

    with {:ok, session} <- Controller.open(ref, [shell: shell_cmd, tty: true] ++ docker_opts),
         {:ok, tui_pid} <- Tui.start_link(tui_opts) do
      {:ok, %{session: session, tui: tui_pid}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:input, bytes}, state) do
    Session.send(state.session, bytes)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:docker_stream, socket, :data, chunk},
        %{session: %Session{socket: socket}} = state
      ) do
    Tui.append(state.tui, strip_ansi(chunk))
    {:noreply, state}
  end

  def handle_info(
        {:docker_stream, socket, :closed},
        %{session: %Session{socket: socket}} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    Tui.stop(state.tui)
    Session.close(state.session)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp cast_input(bridge, bytes), do: GenServer.cast(bridge, {:input, bytes})

  defp resolve_ref(%Instance{id: id}), do: id
  defp resolve_ref(ref) when is_binary(ref), do: Spec.prefix_name(ref)

  defp strip_ansi(bin) do
    bin
    |> String.replace(~r/\e\[[\d;?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/\e\][^\a\e]*(?:\a|\e\\)/, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end
end
