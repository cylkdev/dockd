defmodule Dockd.Core do
  @moduledoc """
  Implementation of the `Dockd` public API.

  `Dockd` is the user-facing module; every function there forwards to a
  matching function here. All provisioning, discovery, destroy, and shell
  logic lives in this module.
  """

  alias Dockd.ApplyResult
  alias Dockd.Error
  alias Dockd.FileCopy
  alias Dockd.Instance
  alias Dockd.Packages
  alias Dockd.Provisioner
  alias Dockd.Spec
  alias Dockd.Spec.Interpolator
  alias Dockd.Spec.Normalizer
  alias Dockd.Spec.Parser
  alias Dockd.Spec.Source

  @log_param_keys [:tail, :since, :until, :follow]
  @log_option_keys [:stdout, :stderr, :timestamps]

  @apply_opts [
    :disk_mount_enabled,
    :socket,
    :host,
    :api_version,
    :platform,
    :networks,
    :network_mode
  ]

  @spec option_keys() :: [atom()]
  def option_keys do
    @apply_opts
  end

  @spec apply(Spec.t() | binary(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
  def apply(spec_or_image, opts \\ [])

  def apply(%Spec{} = spec, opts) when is_list(opts) do
    Provisioner.run(spec, opts)
  end

  def apply(image, opts) when is_binary(image) and is_list(opts) do
    {spec_opts, call_opts} = Keyword.split(opts, Spec.option_keys())

    with :ok <- check_call_opts(call_opts),
         :ok <- check_spec_name(spec_opts) do
      spec = Spec.from_opts(image, spec_opts)
      Provisioner.run(spec, call_opts)
    end
  end

  @spec apply_package(binary(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
  def apply_package(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    path = resolve_package_path(ref)

    with {:ok, body} <- Source.read_file(path),
         {:ok, decoded} <- Parser.parse(body),
         {:ok, substituted} <- Interpolator.substitute(decoded, System.get_env()),
         {:ok, attrs} <- Normalizer.normalize(substituted, Path.dirname(path)),
         :ok <- check_attrs_name(attrs) do
      Provisioner.run(Spec.from_attrs(attrs), opts)
    end
  end

  @spec list(keyword()) :: {:ok, [Instance.t()]} | {:error, Error.t()}
  def list(opts \\ []) when is_list(opts) do
    docker_options = Provisioner.docker_options_from(opts)
    marker = "#{Instance.marker_label()}=true"

    case Docker.list_containers(%{all: true}, [labels: [marker]] ++ docker_options) do
      {:ok, summaries} ->
        hydrate_each(summaries, docker_options, [])

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:discover, "failed to list Docker containers", reason, nil)}
    end
  end

  @spec get(binary(), keyword()) :: {:ok, Instance.t()} | {:error, Error.t()}
  def get(name, opts \\ []) when is_binary(name) and is_list(opts) do
    docker_options = Provisioner.docker_options_from(opts)
    prefixed = Spec.prefix_name(name)

    case Docker.find_container(prefixed, docker_options) do
      {:ok, body} ->
        {:ok, Instance.from_inspect(body)}

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:discover, "failed to inspect Docker container", reason, nil)}
    end
  end

  @spec destroy(Instance.t() | binary(), keyword()) :: :ok | {:error, Error.t()}
  def destroy(instance_or_ref, opts \\ [])

  def destroy(%Instance{id: id}, opts) when is_binary(id) and is_list(opts) do
    Provisioner.destroy(id, opts)
  end

  def destroy(ref, opts) when is_binary(ref) and is_list(opts) do
    prefixed = Spec.prefix_name(ref)
    Provisioner.destroy(prefixed, opts)
  end

  @spec start(Instance.t() | binary(), keyword()) :: :ok | {:error, Error.t()}
  def start(instance_or_ref, opts \\ []) do
    {ref, docker_options} = resolve_ref(instance_or_ref, opts)

    case Docker.start_container(ref, docker_options) do
      {:ok, _} ->
        :ok

      {:error, %{status: 304}} ->
        :ok

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:lifecycle, "failed to start Docker container", reason, nil)}
    end
  end

  @spec stop(Instance.t() | binary(), keyword()) :: :ok | {:error, Error.t()}
  def stop(instance_or_ref, opts \\ []) do
    {ref, docker_options} = resolve_ref(instance_or_ref, opts)

    case Docker.stop_container(ref, docker_options) do
      {:ok, _} ->
        :ok

      {:error, %{status: 304}} ->
        :ok

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:lifecycle, "failed to stop Docker container", reason, nil)}
    end
  end

  @spec restart(Instance.t() | binary(), keyword()) :: :ok | {:error, Error.t()}
  def restart(instance_or_ref, opts \\ []) do
    with :ok <- stop(instance_or_ref, opts) do
      start(instance_or_ref, opts)
    end
  end

  @spec running?(Instance.t() | binary(), keyword()) :: boolean()
  def running?(instance_or_ref, opts \\ []) do
    {ref, docker_options} = resolve_ref(instance_or_ref, opts)
    Docker.container_running?(ref, docker_options)
  end

  @spec logs(Instance.t() | binary(), keyword()) :: Docker.result(binary())
  def logs(instance_or_ref, opts \\ []) do
    {ref, docker_options} = resolve_ref(instance_or_ref, opts)
    {params, log_options} = split_log_opts(opts)
    Docker.container_logs(ref, params, log_options ++ docker_options)
  end

  @spec inspect(Instance.t() | binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def inspect(instance_or_ref, opts \\ []) do
    {ref, docker_options} = resolve_ref(instance_or_ref, opts)

    case Docker.find_container(ref, docker_options) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:discover, "failed to inspect Docker container", reason, nil)}
    end
  end

  @spec refresh(Instance.t() | binary(), keyword()) :: {:ok, Instance.t()} | {:error, Error.t()}
  def refresh(%Instance{} = instance, opts) when is_list(opts) do
    get(Instance.short_name(instance), opts)
  end

  def refresh(ref, opts) when is_binary(ref) and is_list(opts) do
    get(ref, opts)
  end

  def refresh(instance_or_ref), do: refresh(instance_or_ref, [])

  @spec copy_to(Instance.t() | binary(), [map()], keyword()) :: :ok | {:error, Error.t()}
  def copy_to(instance_or_ref, copies, opts \\ []) when is_list(copies) and is_list(opts) do
    case resolve_container_id(instance_or_ref, opts) do
      {:ok, container_id, docker_options} ->
        FileCopy.copy_files(copies, container_id, docker_options)

      {:error, _} = err ->
        err
    end
  end

  @spec list_temp_files(keyword()) :: {:ok, [Path.t()]}
  def list_temp_files(_opts \\ []) do
    {:ok, FileCopy.list_temp_files()}
  end

  @spec delete_temp_files(keyword()) :: :ok
  def delete_temp_files(_opts \\ []) do
    FileCopy.delete_temp_files()
  end

  @spec info(keyword()) ::
          {:ok,
           %{
             temp_files: %{
               count: non_neg_integer(),
               total_bytes: non_neg_integer(),
               oldest_at: DateTime.t() | nil,
               newest_at: DateTime.t() | nil
             }
           }}
  def info(_opts \\ []) do
    {:ok, %{temp_files: FileCopy.temp_files_info()}}
  end

  @spec shell_command(Instance.t() | binary(), [binary()] | binary(), keyword()) ::
          Docker.result(Docker.exec_result())
  def shell_command(instance_or_ref, command, opts \\ []) do
    {ref, instance_opts} = resolve_ref(instance_or_ref, opts)
    Docker.Terminal.run_with_status(ref, command, instance_opts)
  end

  @spec open_shell(Instance.t() | binary(), keyword()) ::
          Docker.result(Docker.Terminal.handle())
  def open_shell(instance_or_ref, opts \\ []) do
    {ref, instance_opts} = resolve_ref(instance_or_ref, opts)

    case Docker.Terminal.open(ref, instance_opts) do
      {:ok, _session} -> {:ok, ref}
      {:error, _} = err -> err
    end
  end

  @spec shell_send(Docker.Terminal.handle(), iodata(), keyword()) ::
          {:ok, {binary() | {binary(), binary()}, Docker.Terminal.handle()}}
          | {:error, {term(), Docker.Terminal.handle()}}
  def shell_send(shell, command, opts \\ []) do
    Docker.Terminal.command(shell, command, opts)
  end

  @spec close_shell(Docker.Terminal.handle()) :: :ok
  def close_shell(shell) do
    Docker.Terminal.close(shell)
  end

  # ---------------------------------------------------------------------------

  defp resolve_ref(%Instance{id: id}, opts) when is_binary(id) do
    {id, Provisioner.docker_options_from(opts)}
  end

  defp resolve_ref(ref, opts) when is_binary(ref) do
    {Spec.prefix_name(ref), Provisioner.docker_options_from(opts)}
  end

  defp resolve_container_id(%Instance{id: id}, opts) when is_binary(id) do
    {:ok, id, Provisioner.docker_options_from(opts)}
  end

  defp resolve_container_id(ref, opts) when is_binary(ref) do
    docker_options = Provisioner.docker_options_from(opts)

    case Docker.find_container(Spec.prefix_name(ref), docker_options) do
      {:ok, %{"Id" => id}} ->
        {:ok, id, docker_options}

      {:ok, body} ->
        {:error,
         Error.docker_phase_error(
           :discover,
           "Docker inspect missing container id",
           body,
           nil
         )}

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:discover, "failed to inspect Docker container", reason, nil)}
    end
  end

  defp split_log_opts(opts) do
    params =
      opts
      |> Keyword.take(@log_param_keys)
      |> Map.new()

    log_options = Keyword.take(opts, @log_option_keys)
    {params, log_options}
  end

  defp hydrate_each([], _docker_options, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp hydrate_each([summary | rest], docker_options, acc) do
    id = Map.get(summary, "Id") || Map.get(summary, "id")

    case Docker.find_container(id, docker_options) do
      {:ok, body} ->
        hydrate_each(rest, docker_options, [Instance.from_inspect(body) | acc])

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:discover, "failed to inspect Docker container", reason, nil)}
    end
  end

  defp check_call_opts(call_opts) do
    case Keyword.keys(call_opts) -- @apply_opts do
      [] ->
        :ok

      [key | _] ->
        {:error, %Error{phase: :validate, message: "unknown option: #{Kernel.inspect(key)}"}}
    end
  end

  defp check_spec_name(spec_opts) do
    case Keyword.get(spec_opts, :name) do
      name when is_binary(name) and name !== "" ->
        :ok

      _ ->
        {:error,
         %Error{phase: :validate, message: "Dockd.apply/2 requires a non-empty :name option"}}
    end
  end

  defp check_attrs_name(attrs) do
    case Map.get(attrs, :name) do
      name when is_binary(name) and name !== "" ->
        :ok

      _ ->
        {:error,
         %Error{
           phase: :validate,
           message: ~s(package is missing a non-empty "name" field)
         }}
    end
  end

  defp resolve_package_path(ref), do: Packages.resolve_path(ref)
end
