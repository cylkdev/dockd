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

  @doc """
  Returns the caller-runtime option keys accepted by `apply/2`.

  These keys configure the Docker daemon connection and provisioning policy —
  `:disk_mount_enabled`, `:socket`, `:host`, `:api_version`, `:platform`,
  `:networks`, and `:network_mode` — rather than the workspace itself. They are
  the options split away from `Dockd.Spec` options (see `Dockd.Spec.option_keys/0`)
  before a spec is built, and `apply/2` rejects any unknown caller option.
  """
  @spec option_keys() :: [atom()]
  def option_keys do
    @apply_opts
  end

  @doc """
  Provisions a container from a `Dockd.Spec` or a bare image reference.

  When given a `%Dockd.Spec{}`, the spec is handed straight to
  `Dockd.Provisioner.run/2`. When given an image string, `opts` is split into
  spec options (see `Dockd.Spec.option_keys/0`) and caller options (see
  `option_keys/0`); both are validated — every caller option must be known and a
  non-empty `:name` is required — before a spec is built and run.

  Returns `{:ok, %Dockd.ApplyResult{}}` on success, or `{:error, %Dockd.Error{}}`
  tagged with the pipeline phase that failed. When a container was created before
  the failure, the error carries a hydrated `Dockd.Instance` so the caller can
  clean up with `destroy/2`.
  """
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

  @doc """
  Provisions a container from a package file (YAML/JSON) referenced by `ref`.

  `ref` is resolved to a path via `Dockd.Packages.resolve_path/1`, then read,
  parsed, environment-interpolated against `System.get_env/0`, and normalized
  into spec attributes. The package must declare a non-empty `"name"`. The
  resulting `Dockd.Spec` is then run through `Dockd.Provisioner.run/2`.

  Returns `{:ok, %Dockd.ApplyResult{}}` or `{:error, %Dockd.Error{}}` — phase
  `:validate` for read/parse/normalize/name problems, otherwise the failing
  provisioning phase.
  """
  @spec apply_package(binary(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
  def apply_package(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    path = resolve_package_path(ref, opts)

    with {:ok, spec} <- load_package_spec(path, nil) do
      Provisioner.run(spec, opts)
    end
  end

  @doc """
  Idempotently brings up an instance from a package, installing the package
  first if it is not already present.

  This is the one-command "install-if-missing, then ensure-running" flow behind
  `dockd instance up`. It runs in three moves:

    1. **Ensure the package is installed.** `ref` is resolved to a package path;
       when that package is absent and a `:source` git URL is supplied, the
       source is cloned and its packages installed (via
       `Dockd.Packages.install_from_git/2`). An already-installed package is
       never re-fetched. Absent with no `:source` is an error.
    2. **Load the spec and fingerprint it.** The package is loaded into a
       `Dockd.Spec` (honouring a `:name` override) and hashed with
       `Dockd.Spec.fingerprint/1`.
    3. **Reconcile against the running world.** If no container with the
       instance name exists, it is provisioned. If one exists, its stored
       fingerprint label is compared with the freshly computed one: an exact
       match means the spec is unchanged and the container is simply started
       (idempotent — an already-running container is a no-op); a mismatch (or a
       missing label, e.g. a container not created by `up`) means the spec has
       drifted, so the old container is destroyed and a fresh one provisioned.

  Recognised keys beyond the standard per-call options:

    - `:source` — git URL to install the package from when it is not present.
    - `:name` — instance name override (defaults to the package's own name).

  Returns `{:ok, summary}` where `summary` is a map:

      %{
        package: :present | :installed,
        action: :created | :started | :running | :recreated,
        instance: Dockd.Instance.t(),
        step_results: [Dockd.StepResult.t()]
      }

  or `{:error, %Dockd.Error{}}`.
  """
  @spec up(binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def up(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    {up_opts, call_opts} = Keyword.split(opts, [:source, :name])
    source = Keyword.get(up_opts, :source)
    name_override = Keyword.get(up_opts, :name)

    with {:ok, pkg_status} <- ensure_package_installed(ref, source, call_opts),
         {:ok, spec} <- load_package_spec(resolve_package_path(ref, call_opts), name_override) do
      fingerprint = Spec.fingerprint(spec)
      reconcile(stamp_fingerprint(spec, fingerprint), fingerprint, pkg_status, call_opts)
    end
  end

  @doc """
  Lists every dockd-managed instance discovered on the Docker daemon.

  Filters all containers (running and stopped) by the discovery marker label
  `org.dockd.instance=true`, then hydrates each match into a `Dockd.Instance`
  via `docker inspect`. `opts` may carry Docker connection options (see
  `Dockd.Provisioner.docker_options_from/1`).

  Returns `{:ok, instances}` or `{:error, %Dockd.Error{}}` tagged `:discover`.
  """
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

  @doc """
  Fetches a single managed instance by workspace `name`.

  The name is prefixed (see `Dockd.Spec.prefix_name/1`) and inspected on the
  daemon. Returns `{:ok, %Dockd.Instance{}}` or `{:error, %Dockd.Error{}}`
  tagged `:discover` when the container is absent or inspect fails.
  """
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

  @doc """
  Stops and removes a managed instance.

  Accepts a `%Dockd.Instance{}` (destroyed by container id) or a workspace
  name/reference (prefixed, then destroyed). Delegates to
  `Dockd.Provisioner.destroy/2`. Returns `:ok` or `{:error, %Dockd.Error{}}`.
  """
  @spec destroy(Instance.t() | binary(), keyword()) :: :ok | {:error, Error.t()}
  def destroy(instance_or_ref, opts \\ [])

  def destroy(%Instance{id: id}, opts) when is_binary(id) and is_list(opts) do
    Provisioner.destroy(id, opts)
  end

  def destroy(ref, opts) when is_binary(ref) and is_list(opts) do
    prefixed = Spec.prefix_name(ref)
    Provisioner.destroy(prefixed, opts)
  end

  @doc """
  Starts a stopped instance.

  Resolves the instance or reference to a container id, then calls
  `Docker.start_container/2`. An already-running container (HTTP 304) is treated
  as success. Returns `:ok` or `{:error, %Dockd.Error{}}` tagged `:lifecycle`.
  """
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

  @doc """
  Stops a running instance.

  Resolves the instance or reference to a container id, then calls
  `Docker.stop_container/2`. An already-stopped container (HTTP 304) is treated
  as success. Returns `:ok` or `{:error, %Dockd.Error{}}` tagged `:lifecycle`.
  """
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

  @doc """
  Restarts an instance by stopping it and then starting it again.

  Short-circuits with the `stop/2` error if stopping fails; otherwise returns
  the result of `start/2`.
  """
  @spec restart(Instance.t() | binary(), keyword()) :: :ok | {:error, Error.t()}
  def restart(instance_or_ref, opts \\ []) do
    with :ok <- stop(instance_or_ref, opts) do
      start(instance_or_ref, opts)
    end
  end

  @doc """
  Returns `true` if the instance or reference resolves to a running container.

  Resolves the target to a container id and queries `Docker.container_running?/2`.
  """
  @spec running?(Instance.t() | binary(), keyword()) :: boolean()
  def running?(instance_or_ref, opts \\ []) do
    {ref, docker_options} = resolve_ref(instance_or_ref, opts)
    Docker.container_running?(ref, docker_options)
  end

  @doc """
  Fetches container logs for an instance.

  Log-window parameters (`:tail`, `:since`, `:until`, `:follow`) and stream
  options (`:stdout`, `:stderr`, `:timestamps`) are split out of `opts` and
  passed to `Docker.container_logs/3`; any remaining options configure the
  Docker connection. Returns the raw `Docker.result/1`.
  """
  @spec logs(Instance.t() | binary(), keyword()) :: Docker.result(binary())
  def logs(instance_or_ref, opts \\ []) do
    {ref, docker_options} = resolve_ref(instance_or_ref, opts)
    {params, log_options} = split_log_opts(opts)
    Docker.container_logs(ref, params, log_options ++ docker_options)
  end

  @doc """
  Returns the raw `docker inspect` map for an instance.

  Unlike `refresh/2`, this returns the unparsed inspect body rather than a
  `Dockd.Instance`. Returns `{:ok, map}` or `{:error, %Dockd.Error{}}` tagged
  `:discover`.
  """
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

  @doc """
  Re-fetches an instance's current state from the daemon.

  Given a `%Dockd.Instance{}`, re-reads it by its short name; given a reference
  string, fetches by that reference. Both delegate to `get/2`, so the returned
  struct reflects the live container. The single-argument form uses default
  options.
  """
  @spec refresh(Instance.t() | binary(), keyword()) :: {:ok, Instance.t()} | {:error, Error.t()}
  def refresh(%Instance{} = instance, opts) when is_list(opts) do
    get(Instance.short_name(instance), opts)
  end

  def refresh(ref, opts) when is_binary(ref) and is_list(opts) do
    get(ref, opts)
  end

  @spec refresh(Instance.t() | binary()) :: {:ok, Instance.t()} | {:error, Error.t()}
  def refresh(instance_or_ref), do: refresh(instance_or_ref, [])

  @doc """
  Copies host files or directories into a running instance.

  `copies` is a list of copy specs (each a map with `:source`/`:dest` and
  related keys). The instance or reference is resolved to a container id, then
  `Dockd.FileCopy.copy_files/3` tars and uploads each entry. Returns `:ok` or
  `{:error, %Dockd.Error{}}`.
  """
  @spec copy_to(Instance.t() | binary(), [map()], keyword()) :: :ok | {:error, Error.t()}
  def copy_to(instance_or_ref, copies, opts \\ []) when is_list(copies) and is_list(opts) do
    case resolve_container_id(instance_or_ref, opts) do
      {:ok, container_id, docker_options} ->
        FileCopy.copy_files(copies, container_id, docker_options)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Lists the temporary archive files dockd has staged on the host.

  These are scratch tarballs produced while copying files into containers.
  Always returns `{:ok, paths}`.
  """
  @spec list_temp_files(keyword()) :: {:ok, [Path.t()]}
  def list_temp_files(_opts \\ []) do
    {:ok, FileCopy.list_temp_files()}
  end

  @doc """
  Deletes all temporary archive files dockd has staged on the host.

  Returns `:ok`.
  """
  @spec delete_temp_files(keyword()) :: :ok
  def delete_temp_files(_opts \\ []) do
    FileCopy.delete_temp_files()
  end

  @doc """
  Returns runtime housekeeping information about dockd.

  Currently reports temp-file statistics: the count of staged files, their
  total size in bytes, and the oldest/newest staged-file timestamps (each `nil`
  when no files exist).
  """
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

  @doc """
  Runs a one-shot command inside an instance and returns its result.

  `command` may be an argv list or a single string. The instance or reference
  is resolved to a container id and executed via
  `Docker.Terminal.run_with_status/3`, capturing stdout/stderr and the exit
  status. Returns a `Docker.result/1` wrapping a `Docker.exec_result/0`.
  """
  @spec shell_command(Instance.t() | binary(), [binary()] | binary(), keyword()) ::
          Docker.result(Docker.exec_result())
  def shell_command(instance_or_ref, command, opts \\ []) do
    {ref, instance_opts} = resolve_ref(instance_or_ref, opts)
    Docker.Terminal.run_with_status(ref, command, instance_opts)
  end

  @doc """
  Opens a long-lived interactive shell session against an instance.

  Resolves the target and calls `Docker.Terminal.open/2`. On success returns
  `{:ok, handle}`, where the handle (the resolved reference) is threaded into
  `shell_send/3` and `close_shell/1`. Returns `{:error, reason}` on failure.
  """
  @spec open_shell(Instance.t() | binary(), keyword()) ::
          Docker.result(Docker.Terminal.handle())
  def open_shell(instance_or_ref, opts \\ []) do
    {ref, instance_opts} = resolve_ref(instance_or_ref, opts)

    configured =
      if Keyword.has_key?(opts, :shell),
        do: nil,
        else: configured_shell(instance_or_ref, opts)

    open_opts = instance_opts ++ resolve_shell_arg(opts, configured)

    case Docker.Terminal.open(ref, open_opts) do
      {:ok, _session} -> {:ok, ref}
      {:error, _} = err -> err
    end
  end

  @doc false
  # Precedence: explicit opts[:shell] wins; else default to the instance's
  # configured program (argv-wrapped); else inject nothing (Docker uses /bin/sh).
  @spec resolve_shell_arg(keyword(), binary() | nil) :: keyword()
  def resolve_shell_arg(opts, configured) do
    cond do
      Keyword.has_key?(opts, :shell) -> []
      is_binary(configured) -> [shell: [configured]]
      true -> []
    end
  end

  # Reads the instance's configured program. Avoids I/O when we already hold the
  # hydrated struct; auto-hydrates a bare ref via get/2 (threading Docker opts).
  defp configured_shell(%Instance{shell: shell}, _opts), do: shell

  defp configured_shell(ref, opts) when is_binary(ref) do
    case get(ref, opts) do
      {:ok, %Instance{shell: shell}} -> shell
      _ -> nil
    end
  end

  @doc """
  Sends a command to an open shell session and returns its output.

  Delegates to `Docker.Terminal.command/3`. On success returns
  `{:ok, {output, handle}}` (where `output` may be a `{stdout, stderr}` tuple);
  on failure `{:error, {reason, handle}}`. The returned handle must be threaded
  into the next call.
  """
  @spec shell_send(Docker.Terminal.handle(), iodata(), keyword()) ::
          {:ok, {binary() | {binary(), binary()}, Docker.Terminal.handle()}}
          | {:error, {term(), Docker.Terminal.handle()}}
  def shell_send(shell, command, opts \\ []) do
    Docker.Terminal.command(shell, command, opts)
  end

  @doc """
  Closes an open shell session. Always returns `:ok`.
  """
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

  defp resolve_package_path(ref, opts), do: Packages.resolve_path(ref, opts)

  # ---------------------------------------------------------------------------
  # up/2 helpers
  # ---------------------------------------------------------------------------

  defp load_package_spec(path, name_override) do
    with {:ok, body} <- Source.read_file(path),
         {:ok, decoded} <- Parser.parse(body),
         {:ok, substituted} <- Interpolator.substitute(decoded, System.get_env()),
         {:ok, attrs} <- Normalizer.normalize(substituted, Path.dirname(path)),
         attrs = override_name(attrs, name_override),
         :ok <- check_attrs_name(attrs) do
      {:ok, Spec.from_attrs(attrs)}
    end
  end

  defp override_name(attrs, name) when is_binary(name) and name !== "",
    do: Map.put(attrs, :name, name)

  defp override_name(attrs, _name), do: attrs

  defp ensure_package_installed(ref, source, opts) do
    if File.exists?(resolve_package_path(ref, opts)) do
      {:ok, :present}
    else
      install_missing_package(ref, source, opts)
    end
  end

  defp install_missing_package(ref, source, opts)
       when is_binary(source) and source !== "" do
    case Packages.install_from_git(source, opts) do
      {:ok, _names} ->
        if File.exists?(resolve_package_path(ref, opts)) do
          {:ok, :installed}
        else
          {:error,
           %Error{
             phase: :validate,
             message:
               "package #{Kernel.inspect(ref)} was not found in source #{Kernel.inspect(source)}"
           }}
        end

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end

  defp install_missing_package(ref, _source, _opts) do
    {:error,
     %Error{
       phase: :validate,
       message:
         "package #{Kernel.inspect(ref)} is not installed; pass --source=<git-url> to install it"
     }}
  end

  defp stamp_fingerprint(%Spec{labels: labels} = spec, fingerprint) do
    %{spec | labels: Map.put(labels || %{}, Instance.fingerprint_label(), fingerprint)}
  end

  # No managed container with this name -> provision fresh. A get/2 error here
  # means the container is absent (the common case) or the daemon is unreachable;
  # either way the subsequent apply/2 surfaces a real failure if one exists.
  defp reconcile(spec, fingerprint, pkg_status, opts) do
    case get(Spec.short_name(spec.name), opts) do
      {:error, %Error{}} ->
        provision(spec, pkg_status, :created, opts)

      {:ok, %Instance{} = instance} ->
        if Map.get(instance.labels || %{}, Instance.fingerprint_label()) == fingerprint do
          start_existing(instance, pkg_status, opts)
        else
          with :ok <- destroy(instance, opts) do
            provision(spec, pkg_status, :recreated, opts)
          end
        end
    end
  end

  defp start_existing(%Instance{running?: running?} = instance, pkg_status, opts) do
    action = if running?, do: :running, else: :started

    with :ok <- start(instance, opts),
         {:ok, fresh} <- refresh(instance, opts) do
      {:ok, %{package: pkg_status, action: action, instance: fresh, step_results: []}}
    end
  end

  defp provision(spec, pkg_status, action, opts) do
    case Provisioner.run(spec, opts) do
      {:ok, %ApplyResult{instance: instance, step_results: step_results}} ->
        {:ok,
         %{package: pkg_status, action: action, instance: instance, step_results: step_results}}

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end
end
