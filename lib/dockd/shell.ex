defmodule Dockd.Shell do
  @moduledoc """
  Opens a real interactive shell into an instance by launching `docker exec -it`
  in a NEW OS terminal window. The new window owns its own TTY, so the calling
  program never surrenders its controlling terminal.

  This is the shell for a *human* to type into. It is distinct from
  `Dockd.open_shell/3`, which is the programmatic, non-TTY form used to drive a
  shell from code.

  ## Everything it needs is an argument

  Unlike the rest of dockd, this module cannot make an API call — it has to hand a
  *command string* to a terminal emulator, which then resolves and runs it. That
  makes three inputs easy to lose:

    * **The daemon.** `connect_command/4` takes `docker_path` and `endpoint` and
      emits `DOCKER_HOST=<endpoint> <docker_path> exec -it …`. Without them the new
      window would run whichever `docker` its own `PATH` found, against whichever
      daemon that CLI's `DOCKER_HOST` or current context pointed at — so a shell
      into an instance on a remote daemon would silently target the local one.
    * **The launcher.** `launcher_path` is positional. `default_launcher_path/0`
      returns the bundled script for callers who want it, as a visible choice.
    * **The terminal emulator.** `terminal` is positional and passed to the
      launcher as `$TERMINAL` instead of being inherited, because it decides both
      *which* emulator opens and whether this call blocks (see below).

  ## Trade-offs

    * **Optimistic success.** `open_window/6` returns `:ok` when the launcher
      *spawned the window*, not when `docker exec` actually attached. If the
      container died between selection and launch, the caller still sees
      success while the new window shows a docker error.
    * **Foreground emulators block.** With a *forking* emulator (macOS
      `osascript`, `gnome-terminal`) `System.cmd` returns immediately. With a
      *foreground* emulator (`xterm`, `konsole`) it blocks until the window is
      closed — so a caller awaiting the result stays pending for the shell's
      lifetime. Pass a forking emulator as `terminal` to avoid this.
  """
  alias Dockd.Instance

  @doc """
  Builds the `docker exec -it <name> <program>` command for a specific daemon.

  `docker_path` is the `docker` CLI to run and `endpoint` is the daemon it should
  talk to, exported as `DOCKER_HOST` so the emulator's own environment cannot
  redirect the shell to a different daemon. `program` overrides the instance's
  configured shell; falls back to `Instance.shell` then `/bin/sh`.
  """
  @spec connect_command(Instance.t(), binary() | nil, Path.t(), binary()) :: binary()
  def connect_command(%Instance{name: name, shell: shell}, program, docker_path, endpoint) do
    prog = program || shell || "/bin/sh"

    "DOCKER_HOST=#{shell_escape(endpoint)} #{shell_escape(docker_path)} " <>
      "exec -it #{shell_escape(name)} #{shell_escape(prog)}"
  end

  @doc """
  Opens a shell for `instance` in a new OS window.

  All four context arguments are required: the `launcher_path` script to run, the
  `terminal` emulator it should open, and the `docker_path` / `endpoint` pair
  identifying the daemon the instance lives on. `opts[:shell]` overrides the
  program.
  """
  @spec open_window(Instance.t(), Path.t(), binary(), Path.t(), binary(), keyword()) ::
          :ok | {:error, binary()}
  def open_window(%Instance{} = instance, launcher_path, terminal, docker_path, endpoint, opts \\ []) do
    cmd = connect_command(instance, opts[:shell], docker_path, endpoint)
    open_terminal(launcher_path, cmd, terminal)
  end

  @doc """
  Runs `launcher` with `cmd`, opening a new window running `terminal`.

  `terminal` is passed as `$TERMINAL` in an explicit environment rather than
  inherited, so which emulator opens is the caller's decision. Maps a
  missing/non-executable launcher (`ErlangError`) or a non-zero exit to
  `{:error, binary()}`.
  """
  @spec open_terminal(Path.t(), binary(), binary()) :: :ok | {:error, binary()}
  def open_terminal(launcher, cmd, terminal) do
    case System.cmd(launcher, [cmd], stderr_to_stdout: true, env: [{"TERMINAL", terminal}]) do
      {_out, 0} -> :ok
      {out, _code} -> {:error, String.trim(out)}
    end
  rescue
    e in ErlangError ->
      {:error, "could not run the shell launcher (#{Exception.message(e)})"}
  end

  @doc """
  Path to the launcher script bundled with dockd.

  A named, opt-in call rather than a fallback inside `open_window/6`: it reads
  `:code.priv_dir/1`, so the value depends on where this build is installed. A
  caller that wants that behaviour asks for it here.
  """
  @spec default_launcher_path() :: Path.t()
  def default_launcher_path, do: Path.join(:code.priv_dir(:dockd), "open-shell")

  defp shell_escape(value) when is_binary(value) do
    if value == "" or not String.match?(value, ~r/^[A-Za-z0-9_@%+=:,.\/-]+$/),
      do: "'" <> String.replace(value, "'", ~s('"'"')) <> "'",
      else: value
  end
end
