defmodule Dockd.Shell do
  @moduledoc """
  Opens a real interactive shell into an instance by launching `docker exec -it`
  in a NEW OS terminal window. The new window owns its own TTY, so the calling
  program never surrenders its controlling terminal.

  This is the shell for a *human* to type into. It is distinct from
  `Dockd.open_shell/2`, which is the programmatic, non-TTY form used to drive a
  shell from code.

  ## Trade-offs

    * **Optimistic success.** `open_window/2` returns `:ok` when the launcher
      *spawned the window*, not when `docker exec` actually attached. If the
      container died between selection and launch, the caller still sees
      success while the new window shows a docker error.
    * **Foreground emulators block.** With a *forking* emulator (macOS
      `osascript`, `gnome-terminal`) `System.cmd` returns immediately. With a
      *foreground* emulator (`xterm`, `konsole`) it blocks until the window is
      closed — so a caller awaiting the result stays pending for the shell's
      lifetime. Set `$TERMINAL` to a
      forking emulator to avoid this.
  """
  alias Dockd.Instance

  @doc """
  Builds the `docker exec -it <name> <program>` command. `program` overrides the
  instance's configured shell; falls back to `Instance.shell` then `/bin/sh`.
  """
  @spec connect_command(Instance.t(), binary() | nil) :: binary()
  def connect_command(%Instance{name: name, shell: shell}, program) do
    prog = program || shell || "/bin/sh"
    "docker exec -it #{shell_escape(name)} #{shell_escape(prog)}"
  end

  @doc """
  Opens a shell for `instance` in a new OS window. `opts[:shell]` overrides the
  program; `opts[:launcher_path]` overrides the bundled launcher (tests only).
  """
  @spec open_window(Instance.t(), keyword()) :: :ok | {:error, binary()}
  def open_window(%Instance{} = instance, opts \\ []) do
    launcher = Keyword.get(opts, :launcher_path, launcher_path())
    program = opts[:shell]
    cmd = connect_command(instance, program)
    open_terminal(launcher, cmd, Instance.short_name(instance))
  end

  @doc """
  Runs `launcher` with `cmd`, opening a new window. Maps a missing/non-executable
  launcher (`ErlangError`) or a non-zero exit to `{:error, binary()}`.
  """
  @spec open_terminal(binary(), binary(), binary()) :: :ok | {:error, binary()}
  def open_terminal(launcher, cmd, _label) do
    case System.cmd(launcher, [cmd], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, _code} -> {:error, String.trim(out)}
    end
  rescue
    e in ErlangError ->
      {:error, "could not run the shell launcher (#{Exception.message(e)})"}
  end

  defp launcher_path, do: Path.join(:code.priv_dir(:dockd), "open-shell")

  defp shell_escape(value) when is_binary(value) do
    if value == "" or not String.match?(value, ~r/^[A-Za-z0-9_@%+=:,.\/-]+$/),
      do: "'" <> String.replace(value, "'", ~s('"'"')) <> "'",
      else: value
  end
end
