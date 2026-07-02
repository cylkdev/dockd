defmodule Mix.Tasks.Dockd.Instance.Run do
  @moduledoc """
  Provision and start a Docker instance.

  The task picks one of four sources for the instance - registry image, Dockerfile,
  JSON package on disk, or installed package by name - calls into `Dockd.apply/2` (or
  `Dockd.apply_package/2` for the file/preset shapes), prints the `docker exec -it`
  invocation the user should run in another terminal, and blocks on `IO.gets/1`.
  Pressing Enter destroys the container and exits.

  ## Responsibilities

    - Parse mutually exclusive source flags (`--image`, `--dockerfile`, `--package`,
      `--preset`) and reject invalid combinations before any side effects
    - Print a phase-tagged action message ("Pulling …", "Building from …", "Loading
      package …", "Loading preset …") so the caller knows what's happening
    - Hand off to `Dockd.apply/2` (or `Dockd.apply_package/2`) and surface its
      phase-tagged errors verbatim
    - Block the invoking terminal until the user presses Enter, then call
      `Dockd.destroy/1` to clean up - the instance is always torn down before the task
      exits successfully

  ## Usage

      mix dockd.instance.run --image IMAGE
      mix dockd.instance.run --dockerfile PATH [--tag TAG]
      mix dockd.instance.run --package PATH
      mix dockd.instance.run --preset NAME
      [any of the above] --name NAME
      [any of the above] --short
      [any of the above] --detached

  ## Examples

  Start a container from a registry image (defaults to `debian:trixie`):

      mix dockd.instance.run
      mix dockd.instance.run --image ubuntu:24.04

  Build and start a container from a Dockerfile:

      mix dockd.instance.run --dockerfile ./Dockerfile
      mix dockd.instance.run --dockerfile ./docker/

  Specify a tag for the built image:

      mix dockd.instance.run --dockerfile ./Dockerfile --tag myapp:dev

  Start a container from a JSON package on disk:

      mix dockd.instance.run --package ./packages/my-stack.json

  Start a container from an installed package:

      mix dockd.instance.run --preset webapp

  Suppress all output except the bare attach command - useful when scripting:

      mix dockd.instance.run --preset webapp --short

  In `--short` mode the task still blocks on Enter and destroys the container when
  released; only the progress and ready/cleanup banners are silenced.

  Start a container and exit without waiting - the container keeps running after the
  task ends, so closing the terminal doesn't tear it down:

      mix dockd.instance.run --preset webapp --detached

  In `--detached` mode the task prints the attach command plus a `docker rm -f` hint
  for cleanup, then returns. Combine with `--short` for scriptable single-line output:

      eval "$(mix dockd.instance.run --preset webapp --short --detached)"

  When detached, the caller is responsible for destroying the container later (via
  `docker rm -f <name>` or `Dockd.destroy/1`).

  Pin a known container name so cleanup doesn't depend on remembering the auto-generated
  one - pairs well with `--detached`:

      mix dockd.instance.run --preset webapp --detached --name web-work
      # ...later, from anywhere:
      docker rm -f web-work

  `--name` overrides any `name` set by a package or preset.
  """
  @shortdoc "Provision and start a Docker instance"

  use Mix.Task

  alias Dockd.ApplyResult
  alias Dockd.Instance
  alias Dockd.Spec
  alias Dockd.Spec.Interpolator
  alias Dockd.Spec.Normalizer
  alias Dockd.Spec.Parser
  alias Dockd.Spec.Source

  @default_image "debian:trixie"
  # Match Dockd's own default; `/bin/sh` is the only shell guaranteed
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
      {:ok, action, {:file, path}} ->
        unless short?, do: Mix.shell().info("#{action} and starting container...")
        run_apply_package(path, opts[:name], short?, detached?)

      {:ok, action, {:opts, image, spec_opts}} ->
        case opts[:name] do
          name when is_binary(name) and name !== "" ->
            spec_opts = Keyword.put(spec_opts, :name, name)
            unless short?, do: Mix.shell().info("#{action} and starting container...")
            run_apply(image, spec_opts, short?, detached?)

          _ ->
            Mix.shell().error("--name is required (e.g. --name work)")
            exit({:shutdown, 1})
        end

      {:error, message} ->
        Mix.shell().error(message)
        exit({:shutdown, 1})
    end
  end

  defp resolve_source(opts) do
    with :ok <- validate_source_flags(opts) do
      build_source(opts)
    end
  end

  defp validate_source_flags(opts) do
    preset = opts[:preset]
    package = opts[:package]
    others = [opts[:dockerfile], opts[:image], opts[:tag]]

    cond do
      preset && (package || Enum.any?(others)) ->
        {:error, "--preset cannot be combined with --package, --image, --dockerfile, or --tag"}

      package && Enum.any?(others) ->
        {:error, "--package cannot be combined with --image, --dockerfile, or --tag"}

      true ->
        :ok
    end
  end

  defp build_source(opts) do
    cond do
      preset = opts[:preset] ->
        {:ok, "Loading preset #{preset}", {:file, resolve_package_path(preset)}}

      package = opts[:package] ->
        {:ok, "Loading package #{package}", {:file, package}}

      dockerfile = opts[:dockerfile] ->
        dockerfile_source(dockerfile, opts[:tag])

      true ->
        image_source(opts[:image])
    end
  end

  defp dockerfile_source(dockerfile, tag_flag) do
    tag = tag_flag || @default_tag

    {:ok, "Building from #{dockerfile}",
     {:opts, tag, [shell: @default_shell, build: %{dockerfile: dockerfile}]}}
  end

  defp image_source(image_flag) do
    image = image_flag || @default_image
    {:ok, "Pulling #{image}", {:opts, image, [shell: @default_shell]}}
  end

  defp resolve_package_path(ref), do: Dockd.Packages.resolve_path(ref)

  defp run_apply_package(path, name, short?, detached?) do
    case load_runnable_spec(path, name) do
      {:ok, spec} ->
        handle_apply(Dockd.apply(spec), short?, detached?)

      {:error, error} ->
        abort_with_error(error)
    end
  end

  defp load_runnable_spec(path, name_override) do
    with {:ok, body} <- Source.read_file(path),
         {:ok, decoded} <- Parser.parse(body),
         {:ok, substituted} <- Interpolator.substitute(decoded, System.get_env()),
         {:ok, attrs} <- Normalizer.normalize(substituted, Path.dirname(path)),
         {:ok, attrs} <- apply_name_override(attrs, name_override) do
      {:ok, Spec.from_attrs(attrs)}
    end
  end

  defp apply_name_override(attrs, nil) do
    case Map.get(attrs, :name) do
      name when is_binary(name) and name !== "" ->
        {:ok, attrs}

      _ ->
        {:error,
         %Dockd.Error{
           phase: :validate,
           message: ~s(package has no "name"; pass --name to supply one)
         }}
    end
  end

  defp apply_name_override(attrs, name) when is_binary(name) and name !== "" do
    {:ok, Map.put(attrs, :name, name)}
  end

  defp run_apply(image, spec_opts, short?, detached?) do
    handle_apply(Dockd.apply(image, spec_opts), short?, detached?)
  end

  defp handle_apply({:ok, %ApplyResult{instance: instance}}, short?, detached?) do
    announce_ready(instance, short?, detached?)
    await_shutdown(instance, short?, detached?)
  end

  defp handle_apply({:error, error}, _short?, _detached?), do: abort_with_error(error)

  defp await_shutdown(_instance, _short?, true = _detached), do: :ok

  defp await_shutdown(instance, short?, false) do
    _ = IO.gets("")
    unless short?, do: Mix.shell().info("Stopping container...")
    _ = Dockd.destroy(instance)
    unless short?, do: Mix.shell().info("Done - container removed.")
    :ok
  end

  defp abort_with_error(error) do
    Mix.shell().error("Failed during #{error.phase}: #{error.message}")
    exit({:shutdown, 1})
  end

  defp announce_ready(instance, true = _short, _detached) do
    command = connect_command(instance)
    IO.write(command <> "\n")
  end

  defp announce_ready(instance, false, true = _detached) do
    Mix.shell().info("""

    Container is ready (detached - will keep running after this task exits).

        Connect: #{connect_command(instance)}
        Destroy: docker rm -f #{instance.name}
    """)
  end

  defp announce_ready(instance, false, false) do
    Mix.shell().info("""

    Container is ready!

    Connect to it by running this command in another terminal:

        #{connect_command(instance)}

    Press Enter here when you're done to stop and remove the container.
    """)
  end

  defp connect_command(%Instance{name: name, shell: shell})
       when is_binary(name) and is_binary(shell),
       do: "docker exec -it #{shell_escape(name)} #{shell_escape(shell)}"

  defp shell_escape(value) when is_binary(value) do
    if value === "" or not String.match?(value, ~r/^[A-Za-z0-9_@%+=:,.\/-]+$/) do
      escaped = String.replace(value, "'", ~s('"'"'))
      "'#{escaped}'"
    else
      value
    end
  end
end
