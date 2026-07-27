defmodule Dockd.Provisioner do
  @moduledoc """
  Runs the create-an-`Instance` pipeline.

  Takes a `Dockd.Spec` (what the user wants) plus a keyword list of
  per-call options (caller runtime context — Docker daemon connection
  settings and the `:disk_mount_enabled` policy) and produces a
  `Dockd.ApplyResult` (the new `Instance` plus any step results).

  All caller-runtime state lives in `opts` and the internal pipeline
  context; nothing about this module's state survives a single call.
  Errors are tagged with the phase that produced them; when a container
  was created before the failure, the error carries a hydrated
  `Dockd.Instance` so callers can clean up with `Dockd.destroy/1`.
  """

  require Logger

  alias Dockd.ApplyResult
  alias Dockd.Error
  alias Dockd.Instance
  alias Dockd.Spec
  alias Dockd.StepResult

  @docker_connection_keys [:socket, :host, :platform, :networks, :network_mode]

  @host_path_keys [:mounts, :repos, :copy]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Runs the full create-an-`Instance` provisioning pipeline for `spec`.

  Builds a per-call context from `spec` and the connection/policy options in
  `opts`, then executes the pipeline in order: enforce disk-mount policy, expand
  env, normalize mounts, validate the image source, normalize step/repo/copy
  specs, resolve the image (build or pull), create and start the container,
  fetch repos, copy host files, run setup steps, and hydrate the resulting
  `Dockd.Instance`.

  Returns `{:ok, %Dockd.ApplyResult{}}` on success. On failure returns
  `{:error, %Dockd.Error{}}` tagged with the phase that failed; when a container
  was already created, the error carries a hydrated (or stub) `Dockd.Instance`
  and any captured `step_results` so the caller can clean up with
  `Dockd.destroy/1`.
  """
  @spec run(Spec.t(), keyword()) :: {:ok, ApplyResult.t()} | {:error, Error.t()}
  def run(%Spec{} = spec, opts \\ []) when is_list(opts) do
    ctx = %{
      spec: spec,
      docker_options: docker_options_from(opts),
      container_id: nil,
      steps: [],
      repos: [],
      copies: [],
      step_results: []
    }

    with {:ok, ctx} <- enforce_disk_mount_policy(ctx, opts),
         {:ok, ctx} <- expand_env(ctx),
         {:ok, ctx} <- normalize_mounts(ctx),
         {:ok, ctx} <- validate_source(ctx),
         {:ok, ctx} <- normalize_step_specs(ctx),
         {:ok, ctx} <- normalize_repo_specs(ctx),
         {:ok, ctx} <- normalize_copy_specs(ctx),
         {:ok, ctx} <- resolve_image(ctx),
         {:ok, ctx} <- create_container(ctx),
         {:ok, ctx} <- start_container(ctx),
         {:ok, ctx} <- download_repos_to_host(ctx),
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
  @spec destroy(binary(), keyword()) :: :ok | {:error, Error.t()}
  def destroy(container_ref, opts \\ []) when is_binary(container_ref) and is_list(opts) do
    docker_options = docker_options_from(opts)

    with :ok <- stop_container_tolerant(container_ref, docker_options) do
      delete_container_tolerant(container_ref, docker_options)
    end
  end

  @doc """
  Extracts the Docker-client connection options from a per-call `opts`
  keyword list. Used by `Dockd` to forward connection settings to
  `Docker.*` calls outside this module.

  Note: the caller-facing `:api_version` key is renamed to `:version`
  before being forwarded, to match the keyword expected by the `Docker`
  client.
  """
  @spec docker_options_from(keyword()) :: keyword()
  def docker_options_from(opts) when is_list(opts) do
    opts
    |> Keyword.take(@docker_connection_keys ++ [:api_version])
    |> rename_keyword(:api_version, :version)
  end

  # ---------------------------------------------------------------------------
  # Pipeline — disk-mount policy
  # ---------------------------------------------------------------------------

  defp enforce_disk_mount_policy(ctx, opts) do
    case Keyword.get(opts, :disk_mount_enabled) do
      nil ->
        {:ok, ctx}

      true ->
        {:ok, ctx}

      false ->
        {:ok, %{ctx | spec: strip_host_exposure(ctx.spec)}}

      other ->
        {:error, validate_error(":disk_mount_enabled must be a boolean, got: #{inspect(other)}")}
    end
  end

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

  defp host_exposure_present?(nil), do: false
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

  defp strip_host_env_entries(spec), do: spec

  defp literal_env_entry?(entry) when is_binary(entry), do: String.contains?(entry, "=")

  defp literal_env_entry?({name, opts}) when is_binary(name) and is_list(opts),
    do: Keyword.has_key?(opts, :value)

  defp literal_env_entry?(_), do: false

  # ---------------------------------------------------------------------------
  # Pipeline — env resolution
  # ---------------------------------------------------------------------------

  defp expand_env(%{spec: %Spec{env: []}} = ctx), do: {:ok, ctx}

  defp expand_env(%{spec: %Spec{env: entries} = spec} = ctx) when is_list(entries) do
    with {:ok, expanded} <- resolve_env_entries(entries) do
      {:ok, %{ctx | spec: %{spec | env: expanded}}}
    end
  end

  defp expand_env(_ctx),
    do: {:error, validate_error(":env must be a list")}

  defp resolve_env_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case resolve_env_entry(entry) do
        {:ok, :drop} -> {:cont, {:ok, acc}}
        {:ok, str} -> {:cont, {:ok, acc ++ [str]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_env_entry(entry) when is_binary(entry) do
    if String.contains?(entry, "=") do
      {:ok, entry}
    else
      case System.fetch_env(entry) do
        {:ok, val} ->
          {:ok, "#{entry}=#{val}"}

        :error ->
          {:error, validate_error(":env references unset host var: #{entry}")}
      end
    end
  end

  defp resolve_env_entry({name, opts}) when is_binary(name) and is_list(opts) do
    if Keyword.has_key?(opts, :value) do
      {:ok, "#{name}=#{Keyword.fetch!(opts, :value)}"}
    else
      resolve_host_env(name, opts)
    end
  end

  defp resolve_env_entry(other),
    do:
      {:error,
       validate_error(
         ":env entries must be strings or {name, opts} tuples, got: #{inspect(other)}"
       )}

  defp resolve_host_env(name, opts) do
    case System.fetch_env(name) do
      {:ok, val} -> {:ok, "#{name}=#{val}"}
      :error -> resolve_unset_host_env(name, opts)
    end
  end

  defp resolve_unset_host_env(name, opts) do
    case Keyword.fetch(opts, :default) do
      {:ok, default} when is_binary(default) ->
        {:ok, "#{name}=#{default}"}

      _ ->
        if Keyword.get(opts, :optional) === true do
          {:ok, :drop}
        else
          {:error, validate_error(":env references unset host var: #{name}")}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline — mounts
  # ---------------------------------------------------------------------------

  defp normalize_mounts(%{spec: %Spec{mounts: []}} = ctx), do: {:ok, ctx}

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
    do: {:error, validate_error(":mounts must be a list")}

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
      [_h, _c] -> {:bind, s}
      [_h, _c, _o] -> {:bind, s}
      _ -> {:error, validate_error("invalid :mounts entry: #{inspect(s)}")}
    end
  end

  defp classify_mount_entry(m) when is_map(m) do
    case Map.get(m, :target) || Map.get(m, "target") do
      target when is_binary(target) and target !== "" ->
        {:mount, atomize_mount_keys(m)}

      _ ->
        {:error, validate_error(":mounts map entry requires a non-empty :target")}
    end
  end

  defp classify_mount_entry(other),
    do: {:error, validate_error("invalid :mounts entry: #{inspect(other)}")}

  defp atomize_mount_keys(m) do
    for {k, v} <- m, into: %{} do
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, v}
    end
  end

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
      {:error, msg} -> {:error, validate_error(msg)}
    end
  end

  defp do_validate_source(_image, %{} = build) do
    case Map.get(build, :dockerfile) || Map.get(build, "dockerfile") do
      df when is_binary(df) ->
        validate_dockerfile_path(df)

      _ ->
        {:error, ":build map must include a :dockerfile path"}
    end
  end

  defp do_validate_source(image, nil) do
    expanded = Path.expand(image)

    if File.regular?(expanded) or File.dir?(expanded) do
      {:error, "local image paths are not supported, use the :build option instead"}
    else
      :ok
    end
  end

  defp validate_dockerfile_path(dockerfile) do
    expanded = Path.expand(dockerfile)

    cond do
      File.regular?(expanded) ->
        :ok

      File.dir?(expanded) ->
        validate_dockerfile_in_dir(expanded, dockerfile)

      true ->
        {:error, "dockerfile path does not exist: #{dockerfile}"}
    end
  end

  defp validate_dockerfile_in_dir(expanded, dockerfile) do
    candidate = Path.join(expanded, "Dockerfile")

    if File.regular?(candidate) do
      :ok
    else
      {:error, "no Dockerfile found in directory: #{dockerfile}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline — normalize steps / repos / copies
  # ---------------------------------------------------------------------------

  defp normalize_step_specs(%{spec: %Spec{steps: specs}} = ctx) when is_list(specs) do
    case do_normalize_steps(specs) do
      {:ok, steps} -> {:ok, %{ctx | steps: steps}}
      {:error, msg} -> {:error, validate_error(msg)}
    end
  end

  defp normalize_step_specs(_ctx),
    do: {:error, validate_error(":steps must be a list")}

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
    step_name = get_value(step_spec, :step_name)
    cmd = get_value(step_spec, :cmd)
    env = get_value(step_spec, :env)
    workdir = get_value(step_spec, :workdir)
    user = get_value(step_spec, :user)
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
    if is_nil(get_value(step_spec, :label)) do
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

  defp normalize_repo_specs(%{spec: %Spec{repos: specs}} = ctx) when is_list(specs) do
    case do_normalize_repos(specs) do
      {:ok, repos} -> {:ok, %{ctx | repos: repos}}
      {:error, msg} -> {:error, validate_error(msg)}
    end
  end

  defp normalize_repo_specs(_ctx),
    do: {:error, validate_error(":repos must be a list")}

  defp do_normalize_repos(specs) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, acc} ->
      case normalize_repo(spec, index) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  defp normalize_repo(spec, index) when is_map(spec) do
    url = get_value(spec, :url)
    dest = get_value(spec, :dest)
    ref = get_value(spec, :ref)
    depth = get_value(spec, :depth)
    history = get_value(spec, :history)
    prefix = "repo #{index + 1}"

    with :ok <- validate_nonempty_binary(url, "#{prefix} must include a non-empty :url"),
         :ok <- validate_nonempty_binary(dest, "#{prefix} must include a non-empty :dest"),
         :ok <- validate_absolute_path(dest, prefix),
         :ok <- validate_optional_binary(ref, "#{prefix} has invalid :ref"),
         :ok <- validate_optional_positive_integer(depth, prefix),
         :ok <- validate_optional_boolean(history, prefix) do
      {:ok, drop_nil(%{url: url, dest: dest, ref: ref, depth: depth, history: history})}
    end
  end

  defp normalize_repo(_spec, index),
    do: {:error, "repo #{index + 1} must be a map"}

  defp validate_absolute_path(dest, prefix) do
    if String.starts_with?(dest, "/") do
      :ok
    else
      {:error, "#{prefix} :dest must be an absolute path inside the container"}
    end
  end

  defp validate_optional_positive_integer(nil, _prefix), do: :ok

  defp validate_optional_positive_integer(value, _prefix) when is_integer(value) and value > 0,
    do: :ok

  defp validate_optional_positive_integer(_value, prefix),
    do: {:error, "#{prefix} :depth must be a positive integer"}

  defp validate_optional_boolean(nil, _prefix), do: :ok
  defp validate_optional_boolean(value, _prefix) when is_boolean(value), do: :ok

  defp validate_optional_boolean(_value, prefix),
    do: {:error, "#{prefix} :history must be a boolean"}

  defp normalize_copy_specs(%{spec: %Spec{copy: specs}} = ctx) when is_list(specs) do
    case do_normalize_copies(specs) do
      {:ok, copies} -> {:ok, %{ctx | copies: copies}}
      {:error, msg} -> {:error, validate_error(msg)}
    end
  end

  defp normalize_copy_specs(_ctx),
    do: {:error, validate_error(":copy must be a list")}

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
    src = get_value(spec, :src)
    dest = get_value(spec, :dest)
    mode = get_value(spec, :mode)
    owner = get_value(spec, :owner)
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

  defp get_value(map, key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp drop_nil(map),
    do: for({k, v} <- map, not is_nil(v), into: %{}, do: {k, v})

  # ---------------------------------------------------------------------------
  # Pipeline — image resolution
  # ---------------------------------------------------------------------------

  defp resolve_image(%{spec: %Spec{build: nil}} = ctx), do: pull_image(ctx)
  defp resolve_image(%{spec: %Spec{build: %{} = build}} = ctx), do: build_image(ctx, build)

  defp pull_image(%{spec: %Spec{image: image}, docker_options: docker_options} = ctx) do
    docker_call(ctx, :pull, "failed to pull Docker image", fn ->
      with {:ok, stream} <- Docker.pull_image(image, %{}, docker_options),
           :ok <- consume_image_stream(stream, :pull) do
        {:ok, image}
      end
    end)
  end

  defp build_image(%{spec: %Spec{image: tag}, docker_options: docker_options} = ctx, build) do
    dockerfile = atomize_key(build, :dockerfile)
    context = atomize_key(build, :context)
    expanded = Path.expand(dockerfile)

    {context_path, dockerfile_path} =
      if File.dir?(expanded) do
        {expanded, Path.join(expanded, "Dockerfile")}
      else
        if context,
          do: {Path.expand(context), expanded},
          else: {Path.dirname(expanded), expanded}
      end

    build_params = build_params_for_engine(build)

    docker_call(ctx, :build, "failed to build Docker image", fn ->
      with {:ok, stream} <-
             Docker.build_image(context_path, dockerfile_path, tag, build_params, docker_options),
           :ok <- consume_image_stream(stream, :build) do
        {:ok, tag}
      end
    end)
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

  defp atomize_key(map, key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  # ---------------------------------------------------------------------------
  # Pipeline — container lifecycle
  # ---------------------------------------------------------------------------

  defp create_container(
         %{
           spec:
             %Spec{instance_name: name, labels: user_labels, image: image, shell: shell, env: env} = spec,
           docker_options: docker_options
         } = ctx
       ) do
    create_options =
      docker_options
      |> maybe_put_interactive_shell(shell)
      |> put_unless_empty(:env, env)

    labels = Map.merge(user_labels || %{}, Instance.managed_labels(spec))

    case Docker.create_container(name, image, labels, create_options) do
      {:ok, container_id} ->
        {:ok, %{ctx | container_id: container_id}}

      {:error, {warnings, container_id}} when is_list(warnings) and is_binary(container_id) ->
        {:ok, %{ctx | container_id: container_id}}

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:create, "failed to create Docker container", reason, nil)}
    end
  end

  defp start_container(%{container_id: container_id, docker_options: docker_options} = ctx) do
    case Docker.start_container(container_id, docker_options) do
      {:ok, _} ->
        {:ok, ctx}

      {:error, reason} ->
        {:error, attach_partial_instance(ctx, :start, "failed to start Docker container", reason)}
    end
  end

  defp download_repos_to_host(
         %{container_id: container_id, docker_options: docker_options, repos: repos} = ctx
       ) do
    case Dockd.Git.download_repos_to_host(repos, container_id, docker_options) do
      :ok -> {:ok, ctx}
      {:error, error} -> {:error, attach_existing_instance(ctx, error)}
    end
  end

  defp copy_files(
         %{container_id: container_id, docker_options: docker_options, copies: copies} = ctx
       ) do
    case Dockd.FileCopy.copy_files(copies, container_id, docker_options) do
      :ok -> {:ok, ctx}
      {:error, error} -> {:error, attach_existing_instance(ctx, error)}
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
        error =
          Error.docker_phase_error(
            :setup,
            "failed to run setup step: #{step.step_name}",
            reason,
            hydrate_or_stub(acc_ctx)
          )

        {:halt, {:error, %{error | step_results: acc_ctx.step_results}}}
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
      error = %Error{
        phase: :setup,
        message: "setup step failed: #{step.step_name}",
        exit_code: exit_code,
        output: output,
        instance: hydrate_or_stub(updated),
        step_results: updated.step_results
      }

      {:halt, {:error, error}}
    end
  end

  defp hydrate(%{container_id: container_id, docker_options: docker_options}) do
    case Docker.find_container(container_id, docker_options) do
      {:ok, body} ->
        {:ok, Instance.from_inspect(body)}

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:discover, "failed to inspect Docker container", reason, nil)}
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
         Error.docker_phase_error(:destroy, "failed to stop Docker container", reason, nil)}
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
         Error.docker_phase_error(:destroy, "failed to delete Docker container", reason, nil)}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp docker_call(ctx, phase, message, fun) do
    case fun.() do
      {:ok, result} ->
        {:ok, Map.put(ctx, :last_docker_result, result)}

      {:error, reason} ->
        {:error, attach_partial_instance(ctx, phase, message, reason)}
    end
  end

  defp attach_partial_instance(ctx, phase, message, reason) do
    error = Error.docker_phase_error(phase, message, reason, nil)
    %{error | instance: hydrate_or_stub(ctx)}
  end

  defp attach_existing_instance(ctx, %Error{} = error) do
    %{error | instance: hydrate_or_stub(ctx)}
  end

  # Best-effort instance hydration for the failure path: try a real inspect
  # first; fall back to a stub carrying just id + prefixed name so the caller
  # can still call destroy/1.
  defp hydrate_or_stub(%{container_id: nil}), do: nil

  defp hydrate_or_stub(%{container_id: container_id, docker_options: docker_options, spec: spec}) do
    case Docker.find_container(container_id, docker_options) do
      {:ok, body} ->
        Instance.from_inspect(body)

      {:error, _} ->
        %Instance{id: container_id, name: spec.instance_name}
    end
  end

  defp validate_error(message), do: %Error{phase: :validate, message: message}

  # Consumes a pull/build NDJSON stream; logs progress events in real time
  # via Dockd.Log and surfaces a stream-level error event as
  # {:error, %{body: ...}} so docker_call can normalize it.
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
      %{seen: _} -> :ok
    end
  end

  defp log_event(%{"status" => status} = event, :pull, acc) do
    id = Map.get(event, "id")
    key = {id, status}

    if MapSet.member?(acc.seen, key) do
      acc
    else
      Dockd.Log.info("pull", format_pull(status, id))
      %{acc | seen: MapSet.put(acc.seen, key)}
    end
  end

  defp log_event(%{"stream" => line}, :build, acc) when is_binary(line) do
    trimmed = String.trim_trailing(line)

    if trimmed == "" do
      acc
    else
      Dockd.Log.info("build", trimmed)
      acc
    end
  end

  defp log_event(%{"aux" => %{"ID" => id}}, :build, acc) when is_binary(id) do
    Dockd.Log.info("build", "built image #{id}")
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
