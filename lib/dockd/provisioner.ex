defmodule Dockd.Provisioner do
  @moduledoc """
  Runs the create-an-`Instance` pipeline.

  Takes a `Dockd.Spec` (what the user wants) plus its required runtime inputs —
  the Docker daemon `endpoint`, the `disk_mount_enabled` policy, the `host_env`
  map, and the host `temp_root` — and produces a `Dockd.ApplyResult` (the new
  `Instance` plus any step results).

  Those four are positional arguments, not options, because the pipeline cannot
  run without them and none of them may be inferred from ambient process state.
  In particular `disk_mount_enabled` fails **closed**: there is no clause that
  treats an absent value as permission to expose the host.

  All caller-runtime state lives in the arguments and the internal pipeline
  context; nothing about this module's state survives a single call. Errors are
  `%ErrorMessage{}` structs tagged with the phase that produced them in
  `details.phase`; when a container was created before the failure,
  `details.instance` carries a hydrated `Dockd.Instance` so callers can clean up
  with `Dockd.destroy/3`.
  """

  require Logger

  alias Dockd.ApplyResult
  alias Dockd.HostTool
  alias Dockd.Instance
  alias Dockd.Spec
  alias Dockd.StepResult

  # :socket and :host are absent by design — the daemon target is the positional
  # `endpoint` argument, so it cannot be forgotten and silently defaulted.
  @docker_option_keys [:api_version, :platform, :networks, :network_mode]

  @host_path_keys [:mounts, :copy]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Runs the full create-an-`Instance` provisioning pipeline for `spec`.

  Builds a per-call context from the arguments, then executes the pipeline in
  order: validate the spec, enforce disk-mount policy, expand env, normalize
  mounts, validate the image source, normalize step/copy specs, resolve the
  image (build or pull), create and start the container, copy host files, run
  setup steps, and hydrate the resulting `Dockd.Instance`.

  Arguments:

    - `spec` — the `Dockd.Spec` to realize
    - `endpoint` — the Docker daemon to talk to, e.g.
      `"unix:///var/run/docker.sock"` or `"tcp://10.0.0.1:2376"`
    - `disk_mount_enabled` — `true` permits host mounts, file copies and
      host-derived env; `false` strips them. No default: an absent policy must
      never mean "expose the host"
    - `host_env` — the environment `:env` entries resolve against. Pass `%{}` to
      resolve nothing from the host
    - `temp_root` — host directory for file-copy staging

  `validate_spec/1` runs first so a hand-built `%Dockd.Spec{}` with a `nil`
  `:image` or `:instance_name` produces a `:validate` error rather than crashing
  further down.

  Returns `{:ok, %Dockd.ApplyResult{}}` on success. On failure returns
  `{:error, %ErrorMessage{}}` with `details.phase` naming the phase that failed;
  when a container was already created, `details.instance` carries a hydrated (or
  stub) `Dockd.Instance` and `details.step_results` whatever was captured, so the
  caller can clean up with `Dockd.destroy/3`.
  """
  @spec run(Spec.t(), binary(), boolean(), %{optional(binary()) => binary()}, Path.t(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, ErrorMessage.t()}
  def run(%Spec{} = spec, endpoint, disk_mount_enabled, host_env, temp_root, opts \\ [])
      when is_map(host_env) and is_list(opts) do
    with {:ok, docker_options} <- docker_options_from(endpoint, opts),
         :ok <- validate_spec(spec),
         :ok <- validate_temp_root(temp_root) do
      ctx = %{
        spec: spec,
        docker_options: docker_options,
        host_env: host_env,
        temp_root: temp_root,
        container_staging_root: Keyword.get(opts, :container_staging_root, "/tmp"),
        container_id: nil,
        steps: [],
        copies: [],
        step_results: []
      }

      run_pipeline(ctx, disk_mount_enabled)
    end
  end

  defp run_pipeline(ctx, disk_mount_enabled) do
    with {:ok, ctx} <- enforce_disk_mount_policy(ctx, disk_mount_enabled),
         {:ok, ctx} <- expand_env(ctx),
         {:ok, ctx} <- normalize_mounts(ctx),
         {:ok, ctx} <- validate_source(ctx),
         {:ok, ctx} <- normalize_step_specs(ctx),
         {:ok, ctx} <- normalize_copy_specs(ctx),
         {:ok, ctx} <- resolve_image(ctx),
         {:ok, ctx} <- create_container(ctx),
         {:ok, ctx} <- start_container(ctx),
         {:ok, ctx} <- copy_files(ctx),
         {:ok, ctx} <- run_steps(ctx),
         {:ok, instance} <- hydrate(ctx) do
      {:ok, %ApplyResult{instance: instance, step_results: ctx.step_results}}
    end
  end

  @doc """
  Stops and removes a container.

  Tolerates 304 (already stopped) and 404 (not found) responses so that
  destroying an already-gone container is a no-op.
  """
  @spec destroy(binary(), binary(), keyword()) :: :ok | {:error, ErrorMessage.t()}
  def destroy(container_ref, endpoint, opts \\ [])
      when is_binary(container_ref) and is_list(opts) do
    with {:ok, docker_options} <- docker_options_from(endpoint, opts),
         :ok <- stop_container_tolerant(container_ref, docker_options) do
      delete_container_tolerant(container_ref, docker_options)
    end
  end

  @doc """
  Builds the Docker-client options for a call against `endpoint`.

  `endpoint` is required and must be a non-empty binary. This is the only place
  the daemon target is assembled, and it can never produce an empty list: with no
  endpoint the `Docker` client would fall back to `DOCKER_HOST`, making *which
  daemon a container is created on* depend on ambient process state.

  A `unix://` endpoint (or a bare filesystem path) becomes `:socket`; anything
  else becomes `:host`. The caller-facing `:api_version` option is renamed to
  `:version` to match the keyword the `Docker` client expects.
  """
  @spec docker_options_from(binary(), keyword()) :: {:ok, keyword()} | {:error, ErrorMessage.t()}
  def docker_options_from(endpoint, opts \\ []) when is_list(opts) do
    with {:ok, connection} <- validate_endpoint(endpoint) do
      extra =
        opts
        |> Keyword.take(@docker_option_keys)
        |> rename_keyword(:api_version, :version)

      {:ok, [connection | extra]}
    end
  end

  defp validate_endpoint(endpoint) when is_binary(endpoint) and endpoint !== "" do
    cond do
      String.starts_with?(endpoint, "unix://") ->
        {:ok, {:socket, String.replace_prefix(endpoint, "unix://", "")}}

      Path.type(endpoint) === :absolute and not String.contains?(endpoint, "://") ->
        {:ok, {:socket, endpoint}}

      true ->
        {:ok, {:host, endpoint}}
    end
  end

  defp validate_endpoint(other) do
    {:error,
     ErrorMessage.bad_request(
       "a Docker endpoint is required, got: #{inspect(other)}. " <>
         ~s(Pass a socket path like "unix:///var/run/docker.sock" or a host like "tcp://10.0.0.1:2376".),
       %{phase: :validate}
     )}
  end

  # ---------------------------------------------------------------------------
  # Pipeline — spec and staging validation
  # ---------------------------------------------------------------------------

  # Re-checked here, not only at the Dockd boundary: @enforce_keys stops an
  # incomplete %Spec{} literal, but not one built with an explicit nil.
  defp validate_spec(spec), do: Spec.validate(spec)

  defp validate_temp_root(root), do: HostTool.staging_root(root, "temp_root")

  # ---------------------------------------------------------------------------
  # Pipeline — disk-mount policy
  # ---------------------------------------------------------------------------

  # No nil clause on purpose. This flag gates every host-exposing feature, so an
  # absent value must be a caller error, never an implicit grant.
  defp enforce_disk_mount_policy(ctx, true), do: {:ok, ctx}

  defp enforce_disk_mount_policy(ctx, false),
    do: {:ok, %{ctx | spec: strip_host_exposure(ctx.spec)}}

  defp enforce_disk_mount_policy(_ctx, other),
    do:
      {:error,
       ErrorMessage.bad_request("disk_mount_enabled must be a boolean, got: #{inspect(other)}", %{
         phase: :validate
       })}

  defp strip_host_exposure(%Spec{} = spec) do
    spec
    |> strip_host_path_keys()
    |> strip_host_env_entries()
  end

  defp strip_host_path_keys(spec) do
    Enum.reduce(@host_path_keys, spec, fn key, acc ->
      value = Map.get(acc, key)

      if host_exposure_present?(value) do
        Logger.error(
          "dockd: disk_mount_enabled=false stripped #{inspect(key)}: #{inspect(value)}"
        )
      end

      Map.put(acc, key, [])
    end)
  end

  defp host_exposure_present?([]), do: false
  defp host_exposure_present?(_), do: true

  defp strip_host_env_entries(%Spec{env: entries} = spec) when is_list(entries) do
    {kept, dropped} = Enum.split_with(entries, &literal_env_entry?/1)

    Enum.each(dropped, fn entry ->
      Logger.error(
        "dockd: disk_mount_enabled=false stripped host-derived :env entry: #{inspect(entry)}"
      )
    end)

    %{spec | env: kept}
  end

  # Fails closed: a non-list :env cannot be split, so it is emptied rather than
  # passed through unstripped. expand_env/1 reports the typed error immediately
  # after, so no error path is lost.
  defp strip_host_env_entries(%Spec{} = spec), do: %{spec | env: []}

  defp literal_env_entry?(entry) when is_binary(entry), do: String.contains?(entry, "=")

  defp literal_env_entry?({name, opts}) when is_binary(name) and is_list(opts),
    do: Keyword.has_key?(opts, :value)

  defp literal_env_entry?(_), do: false

  # ---------------------------------------------------------------------------
  # Pipeline — env resolution
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a spec's `:env` entries against `host_env` into `"NAME=value"` strings.

  Pure, and the same code the pipeline runs, so the resolution rules can be
  checked without a daemon. Each entry resolves as:

    - `"NAME=value"` — a literal, passed through verbatim
    - `"NAME"` — read from `host_env`; absent from it is a `:validate` error

  Two shapes and no precedence rule to remember. "Inherit" always means *from
  the `host_env` map the caller passed*, never from the calling process.
  """
  @spec resolve_env(Spec.t(), %{optional(binary()) => binary()}) ::
          {:ok, [binary()]} | {:error, ErrorMessage.t()}
  def resolve_env(%Spec{env: entries}, host_env) when is_list(entries),
    do: resolve_env_entries(entries, host_env)

  def resolve_env(%Spec{}, _host_env),
    do: {:error, ErrorMessage.bad_request(":env must be a list", %{phase: :validate})}

  # Not merely a fast path. Without it, `expand_env/1`'s only return narrows
  # `spec.env` to the resolved `[binary()]`, and dialyzer then reads
  # `normalize_mounts/1`'s catch-all — the sole ":mounts must be a list"
  # validator — as unreachable. The declared `Spec.t()` is optimistic; a
  # hand-built struct can still violate it at runtime, which is what that
  # validator is for. Keep this clause and `mix dialyzer` stays clean.
  defp expand_env(%{spec: %Spec{env: []}} = ctx), do: {:ok, ctx}

  defp expand_env(%{spec: %Spec{} = spec, host_env: host_env} = ctx) do
    with {:ok, expanded} <- resolve_env(spec, host_env) do
      {:ok, %{ctx | spec: %{spec | env: expanded}}}
    end
  end

  defp resolve_env_entries(entries, host_env) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case resolve_env_entry(entry, host_env) do
        {:ok, str} -> {:cont, {:ok, acc ++ [str]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_env_entry(entry, host_env) when is_binary(entry) do
    if String.contains?(entry, "=") do
      {:ok, entry}
    else
      case Map.fetch(host_env, entry) do
        {:ok, val} ->
          {:ok, "#{entry}=#{val}"}

        :error ->
          {:error,
           ErrorMessage.bad_request(":env references a name absent from host_env: #{entry}", %{
             phase: :validate
           })}
      end
    end
  end

  defp resolve_env_entry(other, _host_env),
    do:
      {:error,
       ErrorMessage.bad_request(":env entries must be strings, got: #{inspect(other)}", %{
         phase: :validate
       })}

  # ---------------------------------------------------------------------------
  # Pipeline — mounts
  # ---------------------------------------------------------------------------

  defp normalize_mounts(
         %{spec: %Spec{mounts: entries} = spec, docker_options: docker_options} = ctx
       )
       when is_list(entries) do
    with {:ok, {binds, mounts}} <- classify_mounts(entries) do
      docker_options =
        docker_options
        |> put_unless_empty(:binds, binds)
        |> put_unless_empty(:mounts, mounts)

      {:ok, %{ctx | spec: %{spec | mounts: []}, docker_options: docker_options}}
    end
  end

  defp normalize_mounts(_ctx),
    do: {:error, ErrorMessage.bad_request(":mounts must be a list", %{phase: :validate})}

  defp classify_mounts(entries) do
    Enum.reduce_while(entries, {:ok, {[], []}}, fn entry, {:ok, {binds, mounts}} ->
      case classify_mount_entry(entry) do
        {:bind, str} -> {:cont, {:ok, {binds ++ [str], mounts}}}
        {:mount, map} -> {:cont, {:ok, {binds, mounts ++ [map]}}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp classify_mount_entry(s) when is_binary(s) do
    case String.split(s, ":", parts: 3) do
      [_h, _c] ->
        {:bind, s}

      [_h, _c, _o] ->
        {:bind, s}

      _ ->
        {:error,
         ErrorMessage.bad_request("invalid :mounts entry: #{inspect(s)}", %{phase: :validate})}
    end
  end

  defp classify_mount_entry(m) when is_map(m) do
    case Map.get(m, :target) do
      target when is_binary(target) and target !== "" ->
        {:mount, m}

      nil ->
        {:error,
         ErrorMessage.bad_request(":mounts map entry requires a :target", %{phase: :validate})}

      other ->
        {:error,
         ErrorMessage.bad_request(
           ":mounts map entry :target must be a non-empty string, got: #{inspect(other)}",
           %{phase: :validate}
         )}
    end
  end

  defp classify_mount_entry(other),
    do:
      {:error,
       ErrorMessage.bad_request("invalid :mounts entry: #{inspect(other)}", %{phase: :validate})}

  defp put_unless_empty(opts, _key, []), do: opts
  defp put_unless_empty(opts, key, val), do: Keyword.put(opts, key, val)

  defp maybe_put_interactive_shell(opts, nil), do: opts
  defp maybe_put_interactive_shell(opts, ""), do: opts
  defp maybe_put_interactive_shell(opts, shell), do: Keyword.put(opts, :interactive_shell, shell)

  # ---------------------------------------------------------------------------
  # Pipeline — image source validation
  # ---------------------------------------------------------------------------

  defp validate_source(%{spec: %Spec{image: image, build: build}} = ctx) do
    case do_validate_source(image, build) do
      :ok -> {:ok, ctx}
      {:error, msg} -> {:error, ErrorMessage.bad_request(msg, %{phase: :validate})}
    end
  end

  defp do_validate_source(_image, %{} = build) do
    case Map.get(build, :dockerfile) do
      df when is_binary(df) ->
        validate_dockerfile_path(df)

      nil ->
        {:error, ":build map must include a :dockerfile path"}

      other ->
        {:error, ":build :dockerfile must be a string path, got: #{inspect(other)}"}
    end
  end

  # No Path.expand: a relative string is simply not a local path dockd accepts,
  # and expanding it here would make the check depend on the caller's CWD.
  defp do_validate_source(image, nil) do
    if File.regular?(image) or File.dir?(image) do
      {:error, "local image paths are not supported, use the :build option instead"}
    else
      :ok
    end
  end

  # `Spec.validate/1` has already guaranteed an absolute path, so this only has
  # to answer whether it exists.
  defp validate_dockerfile_path(dockerfile) do
    cond do
      File.regular?(dockerfile) ->
        :ok

      File.dir?(dockerfile) ->
        validate_dockerfile_in_dir(dockerfile)

      true ->
        {:error, "dockerfile path does not exist: #{dockerfile}"}
    end
  end

  defp validate_dockerfile_in_dir(dir) do
    candidate = Path.join(dir, "Dockerfile")

    if File.regular?(candidate) do
      :ok
    else
      {:error, "no Dockerfile found in directory: #{dir}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline — normalize steps / copies
  # ---------------------------------------------------------------------------

  defp normalize_step_specs(%{spec: %Spec{steps: specs}} = ctx) when is_list(specs) do
    case do_normalize_steps(specs) do
      {:ok, steps} -> {:ok, %{ctx | steps: steps}}
      {:error, msg} -> {:error, ErrorMessage.bad_request(msg, %{phase: :validate})}
    end
  end

  defp normalize_step_specs(_ctx),
    do: {:error, ErrorMessage.bad_request(":steps must be a list", %{phase: :validate})}

  defp do_normalize_steps(step_specs) do
    step_specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {step_spec, index}, {:ok, acc} ->
      case normalize_step(step_spec, index) do
        {:ok, step} -> {:cont, {:ok, acc ++ [step]}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  defp normalize_step(step_spec, index) when is_map(step_spec) do
    step_name = Map.get(step_spec, :step_name)
    cmd = Map.get(step_spec, :cmd)
    env = Map.get(step_spec, :env)
    workdir = Map.get(step_spec, :workdir)
    user = Map.get(step_spec, :user)
    prefix = "step #{index + 1}"

    with :ok <- check_renamed_step_key(step_spec, step_name, prefix),
         :ok <-
           validate_nonempty_binary(step_name, "#{prefix} must include a non-empty :step_name"),
         :ok <- validate_cmd_list(cmd, "#{prefix} must include a non-empty :cmd list"),
         :ok <- validate_optional_binary_list(env, "#{prefix} has invalid :env"),
         :ok <- validate_optional_binary(workdir, "#{prefix} has invalid :workdir"),
         :ok <- validate_optional_binary(user, "#{prefix} has invalid :user") do
      {:ok, %{step_name: step_name, cmd: cmd, env: env, workdir: workdir, user: user}}
    end
  end

  defp normalize_step(_step_spec, index),
    do: {:error, "step #{index + 1} must be a map"}

  # `:label` was renamed to `:step_name` — `label` now only ever means a Docker
  # label. Say so rather than reporting a missing key.
  defp check_renamed_step_key(step_spec, nil, prefix) do
    if is_nil(Map.get(step_spec, :label)) do
      :ok
    else
      {:error, "#{prefix} uses :label, which was renamed to :step_name"}
    end
  end

  defp check_renamed_step_key(_step_spec, _step_name, _prefix), do: :ok

  defp validate_nonempty_binary(value, _msg) when is_binary(value) and value !== "", do: :ok
  defp validate_nonempty_binary(_value, msg), do: {:error, msg}

  defp validate_cmd_list(cmd, msg) when is_list(cmd) and cmd !== [] do
    if Enum.all?(cmd, &is_binary/1), do: :ok, else: {:error, msg}
  end

  defp validate_cmd_list(_cmd, msg), do: {:error, msg}

  defp validate_optional_binary_list(nil, _msg), do: :ok

  defp validate_optional_binary_list(value, msg) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: :ok, else: {:error, msg}
  end

  defp validate_optional_binary_list(_value, msg), do: {:error, msg}

  defp validate_optional_binary(nil, _msg), do: :ok
  defp validate_optional_binary(value, _msg) when is_binary(value), do: :ok
  defp validate_optional_binary(_value, msg), do: {:error, msg}

  defp validate_absolute_path(dest, prefix) do
    if String.starts_with?(dest, "/") do
      :ok
    else
      {:error, "#{prefix} :dest must be an absolute path inside the container"}
    end
  end

  defp normalize_copy_specs(%{spec: %Spec{copy: specs}} = ctx) when is_list(specs) do
    case do_normalize_copies(specs) do
      {:ok, copies} -> {:ok, %{ctx | copies: copies}}
      {:error, msg} -> {:error, ErrorMessage.bad_request(msg, %{phase: :validate})}
    end
  end

  defp normalize_copy_specs(_ctx),
    do: {:error, ErrorMessage.bad_request(":copy must be a list", %{phase: :validate})}

  defp do_normalize_copies(specs) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, acc} ->
      case normalize_copy(spec, index) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  defp normalize_copy(spec, index) when is_map(spec) do
    src = Map.get(spec, :src)
    dest = Map.get(spec, :dest)
    mode = Map.get(spec, :mode)
    owner = Map.get(spec, :owner)
    prefix = "copy #{index + 1}"

    with :ok <- validate_nonempty_binary(src, "#{prefix} must include a non-empty :src"),
         :ok <- validate_nonempty_binary(dest, "#{prefix} must include a non-empty :dest"),
         :ok <- validate_absolute_path(dest, prefix),
         :ok <-
           validate_optional_binary(mode, "#{prefix} :mode must be a string (e.g. \"0600\")"),
         :ok <-
           validate_optional_binary(
             owner,
             "#{prefix} :owner must be a string (e.g. \"root:root\")"
           ) do
      {:ok, drop_nil(%{src: src, dest: dest, mode: mode, owner: owner})}
    end
  end

  defp normalize_copy(_spec, index),
    do: {:error, "copy #{index + 1} must be a map"}

  defp drop_nil(map),
    do: for({k, v} <- map, not is_nil(v), into: %{}, do: {k, v})

  # ---------------------------------------------------------------------------
  # Pipeline — image resolution
  # ---------------------------------------------------------------------------

  defp resolve_image(%{spec: %Spec{build: nil}} = ctx), do: pull_image(ctx)
  defp resolve_image(%{spec: %Spec{build: %{} = build}} = ctx), do: build_image(ctx, build)

  defp pull_image(%{spec: %Spec{image: image}, docker_options: docker_options} = ctx) do
    with {:ok, stream} <- Docker.pull_image(image, %{}, docker_options),
         :ok <- consume_image_stream(stream, :pull) do
      {:ok, Map.put(ctx, :last_docker_result, image)}
    else
      {:error, reason} ->
        {:error,
         ErrorMessage.bad_gateway("failed to pull Docker image", %{phase: :pull, reason: reason})}
    end
  end

  defp build_image(%{spec: %Spec{image: tag}, docker_options: docker_options} = ctx, build) do
    # Both paths are absolute — `Spec.validate/1` rejects anything else, so there
    # is no Path.expand here and no dependency on the caller's CWD.
    dockerfile = Map.get(build, :dockerfile)
    context = Map.get(build, :context)

    {context_path, dockerfile_path} =
      if File.dir?(dockerfile) do
        {dockerfile, Path.join(dockerfile, "Dockerfile")}
      else
        if context,
          do: {context, dockerfile},
          else: {Path.dirname(dockerfile), dockerfile}
      end

    build_params = build_params_for_engine(build)

    with {:ok, stream} <-
           Docker.build_image(context_path, dockerfile_path, tag, build_params, docker_options),
         :ok <- consume_image_stream(stream, :build) do
      {:ok, Map.put(ctx, :last_docker_result, tag)}
    else
      {:error, reason} ->
        {:error,
         ErrorMessage.unprocessable_entity("failed to build Docker image", %{
           phase: :build,
           reason: reason
         })}
    end
  end

  # Build params travel to the Engine as a URL query string, so the ones the
  # API defines as JSON documents (maps/lists) must be encoded before they get
  # there — otherwise URI.encode_query/1 raises on the nested term.
  @json_encoded_build_params [:buildargs, :labels, :cachefrom]

  defp build_params_for_engine(build) do
    build
    |> normalize_build_keys()
    |> Map.drop([:dockerfile, :context])
    |> rename_key(:args, :buildargs)
    |> json_encode_build_params()
  end

  defp json_encode_build_params(params) do
    Enum.reduce(@json_encoded_build_params, params, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} when is_map(value) or is_list(value) ->
          Map.put(acc, key, JSON.encode!(value))

        _ ->
          acc
      end
    end)
  end

  defp normalize_build_keys(map) do
    for {k, v} <- map, into: %{} do
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, v}
    end
  end

  defp rename_key(map, from, to) do
    case Map.pop(map, from) do
      {nil, m} -> m
      {v, m} -> Map.put(m, to, v)
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline — container lifecycle
  # ---------------------------------------------------------------------------

  defp create_container(
         %{
           spec:
             %Spec{instance_name: name, labels: user_labels, image: image, shell: shell, env: env} =
               spec,
           docker_options: docker_options
         } = ctx
       ) do
    create_options =
      docker_options
      |> maybe_put_interactive_shell(shell)
      |> put_unless_empty(:env, env)

    labels = Map.merge(user_labels, Instance.managed_labels(spec))

    case Docker.create_container(Spec.prefix_name(name), image, labels, create_options) do
      {:ok, container_id} ->
        {:ok, %{ctx | container_id: container_id}}

      {:error, {warnings, container_id}} when is_list(warnings) and is_binary(container_id) ->
        {:ok, %{ctx | container_id: container_id}}

      {:error, reason} ->
        {:error,
         ErrorMessage.bad_gateway("failed to create Docker container", %{
           phase: :create,
           reason: reason
         })}
    end
  end

  defp start_container(%{container_id: container_id, docker_options: docker_options} = ctx) do
    case Docker.start_container(container_id, docker_options) do
      {:ok, _} ->
        {:ok, ctx}

      {:error, reason} ->
        {:error,
         ErrorMessage.bad_gateway("failed to start Docker container", %{
           phase: :start,
           reason: reason,
           instance: hydrate_or_stub(ctx)
         })}
    end
  end

  defp copy_files(%{copies: []} = ctx), do: {:ok, ctx}

  defp copy_files(ctx) do
    result =
      Dockd.Files.copy_files(
        ctx.copies,
        ctx.container_id,
        ctx.temp_root,
        ctx.docker_options,
        container_staging_root: ctx.container_staging_root
      )

    case result do
      :ok ->
        {:ok, ctx}

      {:error, %ErrorMessage{details: details} = error} ->
        {:error, %{error | details: Map.put(details, :instance, hydrate_or_stub(ctx))}}
    end
  end

  defp run_steps(
         %{steps: steps, container_id: container_id, docker_options: docker_options} = ctx
       ) do
    Enum.reduce_while(steps, {:ok, ctx}, &run_step(&1, &2, container_id, docker_options))
  end

  defp run_step(step, {:ok, acc_ctx}, container_id, docker_options) do
    exec_options =
      docker_options
      |> put_exec_option(:env, step.env)
      |> put_exec_option(:workdir, step.workdir)
      |> put_exec_option(:user, step.user)

    case Docker.exec_run_with_status(container_id, step.cmd, exec_options) do
      {:ok, %{output: output, exit_code: exit_code}} ->
        handle_step_exec(step, acc_ctx, output, exit_code)

      {:error, reason} ->
        {:halt,
         {:error,
          ErrorMessage.unprocessable_entity("failed to run setup step: #{step.step_name}", %{
            phase: :setup,
            reason: reason,
            instance: hydrate_or_stub(acc_ctx),
            step_results: acc_ctx.step_results
          })}}
    end
  end

  defp handle_step_exec(step, acc_ctx, output, exit_code) do
    step_result = %StepResult{
      step_name: step.step_name,
      cmd: step.cmd,
      output: output,
      exit_code: exit_code,
      env: step.env,
      workdir: step.workdir,
      user: step.user
    }

    updated = %{acc_ctx | step_results: acc_ctx.step_results ++ [step_result]}

    if exit_code in [0, nil] do
      {:cont, {:ok, updated}}
    else
      {:halt,
       {:error,
        ErrorMessage.unprocessable_entity("setup step failed: #{step.step_name}", %{
          phase: :setup,
          exit_code: exit_code,
          output: output,
          instance: hydrate_or_stub(updated),
          step_results: updated.step_results
        })}}
    end
  end

  defp hydrate(%{container_id: container_id, docker_options: docker_options}) do
    case Docker.find_container(container_id, docker_options) do
      {:ok, body} ->
        {:ok, Instance.from_inspect(body)}

      {:error, reason} ->
        {:error,
         ErrorMessage.not_found("failed to inspect Docker container", %{
           phase: :discover,
           reason: reason
         })}
    end
  end

  # ---------------------------------------------------------------------------
  # Destroy
  # ---------------------------------------------------------------------------

  defp stop_container_tolerant(container_ref, docker_options) do
    case Docker.stop_container(container_ref, docker_options) do
      {:ok, _} ->
        :ok

      {:error, %{status: status}} when status in [304, 404] ->
        :ok

      {:error, reason} ->
        {:error,
         ErrorMessage.bad_gateway("failed to stop Docker container", %{
           phase: :destroy,
           reason: reason
         })}
    end
  end

  defp delete_container_tolerant(container_ref, docker_options) do
    case Docker.delete_container(container_ref, %{force: true}, docker_options) do
      {:ok, _} ->
        :ok

      {:error, %{status: 404}} ->
        :ok

      {:error, reason} ->
        {:error,
         ErrorMessage.bad_gateway("failed to delete Docker container", %{
           phase: :destroy,
           reason: reason
         })}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Best-effort instance hydration for the failure path: try a real inspect
  # first; fall back to a stub carrying just id + prefixed name so the caller
  # can still call destroy/1.
  defp hydrate_or_stub(%{container_id: nil}), do: nil

  defp hydrate_or_stub(%{container_id: container_id, docker_options: docker_options, spec: spec}) do
    case Docker.find_container(container_id, docker_options) do
      {:ok, body} ->
        Instance.from_inspect(body)

      {:error, _} ->
        # %Instance.name is the container name, so it carries the prefix.
        %Instance{id: container_id, name: Spec.prefix_name(spec.instance_name)}
    end
  end

  # Consumes a pull/build NDJSON stream; logs progress events in real time
  # via Logger and surfaces a stream-level error event as {:error, %{body: ...}},
  # which the pull/build caller puts on the error's `details.reason`.
  defp consume_image_stream(stream, phase) do
    result =
      Enum.reduce_while(stream, %{seen: MapSet.new()}, fn event, acc ->
        case event do
          %{"error" => msg} ->
            {:halt, {:error, %{body: msg}}}

          %{"errorDetail" => %{"message" => msg}} ->
            {:halt, {:error, %{body: msg}}}

          _ ->
            {:cont, log_event(event, phase, acc)}
        end
      end)

    case result do
      {:error, _} = err -> err
      _acc -> :ok
    end
  end

  defp log_event(%{"status" => status} = event, :pull, acc) do
    id = Map.get(event, "id")
    key = {id, status}

    if MapSet.member?(acc.seen, key) do
      acc
    else
      Logger.info("[dockd] pull: #{format_pull(status, id)}")
      %{acc | seen: MapSet.put(acc.seen, key)}
    end
  end

  defp log_event(%{"stream" => line}, :build, acc) when is_binary(line) do
    trimmed = String.trim_trailing(line)

    if trimmed == "" do
      acc
    else
      Logger.info("[dockd] build: #{trimmed}")
      acc
    end
  end

  defp log_event(%{"aux" => %{"ID" => id}}, :build, acc) when is_binary(id) do
    Logger.info("[dockd] build: built image #{id}")
    acc
  end

  defp log_event(_event, _phase, acc), do: acc

  defp format_pull(status, nil), do: status
  defp format_pull(status, id), do: "#{status} #{id}"

  defp rename_keyword(kw, from, to) do
    case Keyword.pop(kw, from) do
      {nil, k} -> k
      {v, k} -> Keyword.put(k, to, v)
    end
  end

  defp put_exec_option(options, _key, nil), do: options
  defp put_exec_option(options, key, value), do: Keyword.put(options, key, value)
end
