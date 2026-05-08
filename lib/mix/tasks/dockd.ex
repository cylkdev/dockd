defmodule Mix.Tasks.Dockd do
  @moduledoc """
  A CLI front-end for `Dockd` that starts an ephemeral Docker workspace and prints the
  attach command.

  The task picks one of four sources for the workspace — registry image, Dockerfile,
  JSON package on disk, or bundled package by name — calls into `Dockd.prepare/2` (or
  `Dockd.Package.load/1` first), prints the `docker exec -it` invocation the user should
  run in another terminal, and blocks on `IO.gets/1`. Pressing Enter destroys the
  container and exits.

  ## Responsibilities

    - Parse mutually exclusive source flags (`--image`, `--dockerfile`, `--package`,
      `--preset`) and reject invalid combinations before any side effects
    - Print a phase-tagged action message ("Pulling …", "Building from …", "Loading
      package …", "Loading preset …") so the caller knows what's happening
    - Hand off to `Dockd.prepare/2` and surface its phase-tagged errors verbatim
    - Block the invoking terminal until the user presses Enter, then call
      `Dockd.destroy/1` to clean up — the workspace is always torn down before the task
      exits successfully

  ## Usage

      mix dockd --image IMAGE
      mix dockd --dockerfile PATH [--tag TAG]
      mix dockd --package PATH
      mix dockd --preset NAME
      [any of the above] --name NAME
      [any of the above] --short
      [any of the above] --detached

  ## Examples

  Start a container from a registry image (defaults to `debian:trixie`):

      mix dockd
      mix dockd --image ubuntu:24.04

  Build and start a container from a Dockerfile:

      mix dockd --dockerfile ./Dockerfile
      mix dockd --dockerfile ./docker/

  Specify a tag for the built image:

      mix dockd --dockerfile ./Dockerfile --tag myapp:dev

  Start a container from a JSON package on disk (see `Dockd.Package`):

      ANTHROPIC_API_KEY=<your-key> mix dockd --package ./packages/my-stack.json

  Start a container from a bundled package (resolved to `priv/packages/<NAME>.json`):

      ANTHROPIC_API_KEY=<your-key> mix dockd --preset claude_code_live_workspace

  Suppress all output except the bare attach command — useful when scripting:

      mix dockd --preset claude_code_live_workspace --short

  In `--short` mode the task still blocks on Enter and destroys the container when
  released; only the progress and ready/cleanup banners are silenced.

  Start a container and exit without waiting — the container keeps running after the
  task ends, so closing the terminal doesn't tear it down:

      mix dockd --preset claude_code_live_workspace --detached

  In `--detached` mode the task prints the attach command plus a `docker rm -f` hint
  for cleanup, then returns. Combine with `--short` for scriptable single-line output:

      eval "$(mix dockd --preset claude_code_live_workspace --short --detached)"

  When detached, the caller is responsible for destroying the container later (via
  `docker rm -f <name>` or `Dockd.destroy/1`).

  Pin a known container name so cleanup doesn't depend on remembering the auto-generated
  one — pairs well with `--detached`:

      mix dockd --preset claude_code_live_workspace --detached --name claude-work
      # ...later, from anywhere:
      docker rm -f claude-work

  `--name` overrides any `name` set by a package or preset.
  """
  @shortdoc "Start a Docker workspace"

  use Mix.Task

  @default_image "debian:trixie"
  # Match Dockd.prepare/2's own default; `/bin/sh` is the only shell guaranteed
  # to exist in nearly every Linux base image (notably busybox-based ones).
  # When a user wants `bash`, they can pass it via a package or `:shell` option.
  @default_shell "/bin/sh"

  @default_tag "dockd-build:latest"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          image: :string,
          dockerfile: :string,
          tag: :string,
          package: :string,
          preset: :string,
          name: :string,
          short: :boolean,
          detached: :boolean
        ]
      )

    short? = opts[:short] || false
    detached? = opts[:detached] || false

    case resolve_source(opts) do
      {:ok, action, image, prepare_opts} ->
        prepare_opts = with_name(prepare_opts, opts[:name])
        unless short?, do: Mix.shell().info("#{action} and starting container...")
        run_prepare(image, prepare_opts, short?, detached?)

      {:error, message} ->
        Mix.shell().error(message)
        exit({:shutdown, 1})
    end
  end

  defp with_name(prepare_opts, nil), do: prepare_opts
  defp with_name(prepare_opts, name), do: Keyword.put(prepare_opts, :name, name)

  defp resolve_source(opts) do
    preset = opts[:preset]
    package = opts[:package]
    dockerfile = opts[:dockerfile]
    image_flag = opts[:image]
    tag_flag = opts[:tag]

    cond do
      preset && (package || dockerfile || image_flag || tag_flag) ->
        {:error, "--preset cannot be combined with --package, --image, --dockerfile, or --tag"}

      package && (dockerfile || image_flag || tag_flag) ->
        {:error, "--package cannot be combined with --image, --dockerfile, or --tag"}

      preset ->
        case Dockd.Package.load(preset) do
          {:ok, {image, prepare_opts}} ->
            {:ok, "Loading preset #{preset}", image, prepare_opts}

          {:error, error} ->
            {:error, "Failed during #{error.phase}: #{error.message}"}
        end

      package ->
        case Dockd.Package.load(package) do
          {:ok, {image, prepare_opts}} ->
            {:ok, "Loading package #{package}", image, prepare_opts}

          {:error, error} ->
            {:error, "Failed during #{error.phase}: #{error.message}"}
        end

      dockerfile ->
        tag = tag_flag || @default_tag

        {:ok, "Building from #{dockerfile}", tag,
         [shell: @default_shell, build: %{dockerfile: dockerfile}]}

      true ->
        image = image_flag || @default_image
        {:ok, "Pulling #{image}", image, [shell: @default_shell]}
    end
  end

  defp run_prepare(image, prepare_opts, short?, detached?) do
    case Dockd.prepare(image, prepare_opts) do
      {:ok, session} ->
        announce_ready(session, short?, detached?)

        unless detached? do
          IO.gets("")
          unless short?, do: Mix.shell().info("Stopping container...")
          Dockd.destroy(session)
          unless short?, do: Mix.shell().info("Done — container removed.")
        end

      {:error, error} ->
        Mix.shell().error("Failed during #{error.phase}: #{error.message}")
        exit({:shutdown, 1})
    end
  end

  defp announce_ready(session, true = _short, _detached), do: IO.puts(session.shell_command)

  defp announce_ready(session, false, true = _detached) do
    Mix.shell().info("""

    Container is ready (detached — will keep running after this task exits).

        Connect: #{session.shell_command}
        Destroy: docker rm -f #{session.container_name}
    """)
  end

  defp announce_ready(session, false, false) do
    Mix.shell().info("""

    Container is ready!

    Connect to it by running this command in another terminal:

        #{session.shell_command}

    Press Enter here when you're done to stop and remove the container.
    """)
  end
end
