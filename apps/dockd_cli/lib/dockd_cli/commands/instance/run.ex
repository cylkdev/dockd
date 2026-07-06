defmodule DockdCLI.Commands.Instance.Run do
  @moduledoc "Provision and start a Docker instance, then wait to tear it down."

  alias Dockd.ApplyResult
  alias Dockd.Instance
  alias Dockd.Spec
  alias Dockd.Spec.Interpolator
  alias Dockd.Spec.Normalizer
  alias Dockd.Spec.Parser
  alias Dockd.Spec.Source
  alias DockdCLI.Json
  alias DockdCLI.Output

  @default_image "debian:trixie"
  @default_shell "/bin/sh"
  @default_tag "dockd-build:latest"

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(args, opts) do
    short? = args[:short] || false
    detached? = args[:detached] || false

    with :ok <- validate_source_flags(args) do
      case build_source(args) do
        {:ok, action, {:file, path}} ->
          unless short?, do: Output.info("#{action} and starting container...")
          run_apply_package(path, args[:name], short?, detached?, opts)

        {:ok, action, {:opts, image, spec_opts}} ->
          run_from_image(args, image, spec_opts, action, short?, detached?, opts)
      end
    end
  end

  @spec run_json(map(), keyword()) :: :ok | {:error, term()}
  def run_json(args, opts) do
    detached? = args[:detached] || false

    with :ok <- validate_source_flags(args) do
      case build_source(args) do
        {:ok, _action, {:file, path}} ->
          case load_runnable_spec(path, args[:name]) do
            {:ok, spec} -> handle_apply_json(Dockd.apply(spec, opts), detached?, opts)
            {:error, error} -> {:error, error}
          end

        {:ok, _action, {:opts, image, spec_opts}} ->
          run_from_image_json(args, image, spec_opts, detached?, opts)
      end
    end
  end

  defp run_from_image_json(args, image, spec_opts, detached?, opts) do
    case args[:name] do
      name when is_binary(name) and name != "" ->
        spec_opts = Keyword.put(spec_opts, :name, name)
        handle_apply_json(Dockd.apply(image, spec_opts ++ opts), detached?, opts)

      _ ->
        {:error, "--name is required (e.g. --name work)"}
    end
  end

  defp handle_apply_json({:ok, %ApplyResult{instance: instance}}, detached?, opts) do
    Output.json(Json.instance(instance))
    await_shutdown_json(instance, detached?, opts)
  end

  defp handle_apply_json({:error, error}, _detached?, _opts), do: {:error, error}

  defp await_shutdown_json(_instance, true, _opts), do: :ok

  defp await_shutdown_json(instance, false, opts) do
    _ = IO.gets("")
    _ = Dockd.destroy(instance, opts)
    :ok
  end

  @spec validate_source_flags(map()) :: :ok | {:error, binary()}
  def validate_source_flags(args) do
    preset = args[:preset]
    package = args[:package]
    others = [args[:dockerfile], args[:image], args[:tag]]

    cond do
      preset && (package || Enum.any?(others)) ->
        {:error, "--preset cannot be combined with --package, --image, --dockerfile, or --tag"}

      package && Enum.any?(others) ->
        {:error, "--package cannot be combined with --image, --dockerfile, or --tag"}

      true ->
        :ok
    end
  end

  defp run_from_image(args, image, spec_opts, action, short?, detached?, opts) do
    case args[:name] do
      name when is_binary(name) and name != "" ->
        spec_opts = Keyword.put(spec_opts, :name, name)
        unless short?, do: Output.info("#{action} and starting container...")
        handle_apply(Dockd.apply(image, spec_opts ++ opts), short?, detached?, opts)

      _ ->
        {:error, "--name is required (e.g. --name work)"}
    end
  end

  defp build_source(args) do
    cond do
      preset = args[:preset] ->
        {:ok, "Loading preset #{preset}", {:file, Dockd.Packages.resolve_path(preset)}}

      package = args[:package] ->
        {:ok, "Loading package #{package}", {:file, package}}

      dockerfile = args[:dockerfile] ->
        {:ok, "Building from #{dockerfile}",
         {:opts, args[:tag] || @default_tag,
          [shell: @default_shell, build: %{dockerfile: dockerfile}]}}

      true ->
        image = args[:image] || @default_image
        {:ok, "Pulling #{image}", {:opts, image, [shell: @default_shell]}}
    end
  end

  defp run_apply_package(path, name, short?, detached?, opts) do
    case load_runnable_spec(path, name) do
      {:ok, spec} -> handle_apply(Dockd.apply(spec, opts), short?, detached?, opts)
      {:error, error} -> {:error, format_error(error)}
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
      name when is_binary(name) and name != "" ->
        {:ok, attrs}

      _ ->
        {:error,
         %Dockd.Error{
           phase: :validate,
           message: ~s(package has no "name"; pass --name to supply one)
         }}
    end
  end

  defp apply_name_override(attrs, name) when is_binary(name) and name != "",
    do: {:ok, Map.put(attrs, :name, name)}

  defp handle_apply({:ok, %ApplyResult{instance: instance}}, short?, detached?, opts) do
    announce_ready(instance, short?, detached?)
    await_shutdown(instance, short?, detached?, opts)
  end

  defp handle_apply({:error, error}, _short?, _detached?, _opts),
    do: {:error, format_error(error)}

  defp format_error(%Dockd.Error{} = err), do: "Failed during #{err.phase}: #{err.message}"
  defp format_error(other), do: other

  defp await_shutdown(_instance, _short?, true, _opts), do: :ok

  defp await_shutdown(instance, short?, false, opts) do
    _ = IO.gets("")
    unless short?, do: Output.info("Stopping container...")
    _ = Dockd.destroy(instance, opts)
    unless short?, do: Output.info("Done - container removed.")
    :ok
  end

  defp announce_ready(instance, true, _detached),
    do: Output.write(shell_hint(instance) <> "\n")

  defp announce_ready(instance, false, true) do
    Output.info("""

    Container is ready (detached - will keep running after this task exits).

        Open a shell: #{shell_hint(instance)}
        Destroy:      docker rm -f #{instance.name}
    """)
  end

  defp announce_ready(instance, false, false) do
    Output.info("""

    Container is ready!

    Open a shell in another terminal with:

        #{shell_hint(instance)}

    Press Enter here when you're done to stop and remove the container.
    """)
  end

  @doc """
  The command a user runs to open a shell in this instance. `run` owns no
  shell-opening logic of its own — it points at `dockd instance shell`, the
  single source of truth for interactive access.
  """
  @spec shell_hint(Instance.t()) :: binary()
  def shell_hint(%Instance{} = instance),
    do: "dockd instance shell --name #{Instance.short_name(instance)}"
end
