defmodule Mix.Tasks.Dockd.Ssh.DialStdioScript.Generate do
  @shortdoc "Generates the dial-stdio wrapper script to disk"
  @moduledoc """
  Renders the bundled `dial-stdio` wrapper script template to disk so you can
  inspect or customise it before installing it on a remote host. See
  `Dockd.Ssh.DockerDialStdio`.

  ## Usage

      mix dockd.ssh.dial_stdio_script.generate [--output-dir DIR] [--force]

  ## Options

    * `--output-dir` -- directory to write the script into. Defaults to the
      current working directory. The directory is created if it does not
      exist.
    * `--force` -- overwrite an existing file. Without this flag the task
      aborts if the target already exists, to avoid clobbering local edits.

  The output filename is always `docker_dial_stdio_script.sh` so that
  `mix dockd.ssh.install_dial_stdio_script` can pick it up automatically from
  the current directory on subsequent runs.

  The generated file is marked executable (mode `0o755`).
  """
  use Mix.Task

  alias Dockd.Ssh.DockerDialStdio

  @output_filename "docker_dial_stdio_script.sh"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _positional, _invalid} =
      OptionParser.parse(argv,
        strict: [
          output_dir: :string,
          force: :boolean
        ]
      )

    output_dir = Keyword.get(opts, :output_dir, File.cwd!())
    force? = Keyword.get(opts, :force, false)
    target = Path.join(output_dir, @output_filename)

    existed? = File.exists?(target)

    if existed? and not force? do
      Mix.raise(
        "#{target} already exists. Re-run with --force to overwrite, " <>
          "or pass --output-dir DIR to write elsewhere."
      )
    end

    File.mkdir_p!(output_dir)
    File.write!(target, DockerDialStdio.render_script([]))
    File.chmod!(target, 0o755)

    suffix = if existed?, do: " (overwrote existing)", else: ""
    Mix.shell().info("Generated #{target}#{suffix}")
    :ok
  end
end
