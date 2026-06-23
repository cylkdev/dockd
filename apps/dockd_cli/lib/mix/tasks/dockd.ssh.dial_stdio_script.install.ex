defmodule Mix.Tasks.Dockd.Ssh.DialStdioScript.Install do
  @shortdoc "Deploys the dial-stdio wrapper script to a remote SSH host"
  @moduledoc """
  Deploys the `dial-stdio` wrapper script - see `Dockd.Ssh.DockerDialStdio` -
  to a remote SSH host.

  ## Usage

      mix dockd.ssh.dial_stdio_script.install USER_AT_HOST [opts]

  ## Options

    * `--script-path` -- explicit local path to the script to upload. When
      set, this file is used verbatim (no template rendering). The task
      aborts if the file does not exist.
    * `--remote-path` -- destination path on the host. Defaults to
      `Dockd.Ssh.DockerDialStdio.default_remote_path/0`.
    * `--identity` -- passed through to `scp`/`ssh` as `-i`.
    * `--port` -- SSH port (passed as `-P` to `scp` and `-p` to `ssh`).

  ## Script source resolution

  When `--script-path` is *not* set, the task resolves the script source as:

    1. If `./docker_dial_stdio_script.sh` exists in the current working
       directory, use that file (so you can `mix
       dockd.ssh.dial_stdio_script.generate`, edit, and re-run install).
    2. Otherwise, render the bundled EEx template in memory and stream it
       to the host over SSH stdin. No local file is created.

  On success the task prints:

      Installed <source> → user@host:<remote_path>

  Where `<source>` is the explicit path, `./docker_dial_stdio_script.sh`, or
  `bundled template (in-memory)` depending on which branch ran.
  """
  use Mix.Task

  alias Dockd.Ssh.DockerDialStdio

  @cwd_filename "docker_dial_stdio_script.sh"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, positional, _invalid} =
      OptionParser.parse(argv,
        strict: [
          script_path: :string,
          remote_path: :string,
          identity: :string,
          port: :string
        ]
      )

    user_at_host = parse_user_at_host(positional)
    {script_source, source_description} = resolve_source(Keyword.get(opts, :script_path))
    install_opts = Keyword.delete(opts, :script_path)

    case DockerDialStdio.install(script_source, user_at_host, install_opts) do
      {:ok, %{remote_path: remote_path}} ->
        Mix.shell().info("Installed #{source_description} → #{user_at_host}:#{remote_path}")
        :ok

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp resolve_source(nil) do
    cwd_path = Path.join(File.cwd!(), @cwd_filename)

    if File.exists?(cwd_path) do
      {cwd_path, "./#{@cwd_filename}"}
    else
      {:default, "bundled template (in-memory)"}
    end
  end

  defp resolve_source(explicit_path) do
    unless File.exists?(explicit_path) do
      Mix.raise("--script-path #{explicit_path} does not exist")
    end

    {explicit_path, explicit_path}
  end

  defp parse_user_at_host([]) do
    Mix.raise(
      "missing required USER_AT_HOST argument. " <>
        "Usage: mix dockd.ssh.dial_stdio_script.install USER_AT_HOST " <>
        "[--script-path PATH] [--remote-path PATH] [--identity FILE] [--port PORT]"
    )
  end

  defp parse_user_at_host([user_at_host | _rest]), do: user_at_host
end
