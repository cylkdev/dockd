defmodule Dockd do
  @moduledoc """
  Public API for dockd.

  Dockd manages local Docker containers as named instances ("instances"). The
  API is intentionally stateless: there is no in-process registry, no GenServer,
  no local store, and nothing derived is cached anywhere. Every container that
  dockd creates carries the marker label `org.dockd.instance=true` plus its
  instance name as `org.dockd.instance.name`, so a fresh BEAM can rediscover the
  full set of managed instances by querying Docker alone.

  ## Getting Started

  You have a Docker daemon running and you want a Linux box you can run
  commands in. Here is the whole lifecycle — create it, work in it, put it
  aside, pick it back up, throw it away.

  ### Decide the four inputs once

  Every call needs the daemon; anything that touches your disk also needs the
  policy, the env slice, and the staging directory. Name them once at the top of
  your code and pass them down:

      endpoint  = "unix:///var/run/docker.sock"
      temp_root = System.tmp_dir!()

      # false: this instance gets no host mounts, no file copies, no host env.
      # Start here and open it up only when you need to.
      allow_disk = false

  ### Create the instance

  Name an image and a name for the box. You get back a running container:

      > {:ok, %Dockd.ApplyResult{instance: instance}} =
      ...>   Dockd.apply_image("debian:trixie", "scratch", endpoint, allow_disk,
      ...>     %{}, temp_root, shell: "/bin/bash")

      > instance.name
      "dockd-scratch"

  You passed `"scratch"`; the container is called `dockd-scratch`. The prefix is
  how dockd knows which containers are its own, and you can use either form
  anywhere an instance is expected.

  **Set `:shell`.** It is what keeps the box alive. Without it an image like
  `debian` runs its command, exits, and your next call fails with "container is
  not running".

  Need setup work done before you call it ready? Add steps. Each one runs in
  order, and you get its output back:

      > {:ok, %Dockd.ApplyResult{step_results: [update, curl]}} =
      ...>   Dockd.apply_image("debian:trixie", "builder", endpoint, allow_disk,
      ...>     %{}, temp_root,
      ...>     shell: "/bin/bash",
      ...>     steps: [
      ...>       %{step_name: "update", cmd: ["apt-get", "update"]},
      ...>       %{step_name: "curl", cmd: ["apt-get", "install", "-y", "curl"]}
      ...>     ])

      > curl.exit_code
      0

  If a step fails, the whole call fails — but the container it already created
  comes back on the error at `details.instance`, so you can read its logs and
  then destroy it rather than leak it.

  ### Run commands in it

  See "One-shot commands" and "Longer-term interactive shells" just below. The
  short version:

      > {:ok, %{output: "hello\\n", exit_code: 0}} =
      ...>   Dockd.shell_command(instance, "echo hello", endpoint)

  ### Put files in it

  `src` must be an absolute path on your machine; `dest` is where it lands
  inside the box:

      > :ok =
      ...>   Dockd.copy_to(instance, [%{src: "/srv/app.env", dest: "/etc/app.env"}],
      ...>     temp_root, endpoint)

  The container gets its own copy — editing the file inside it does not change
  yours. Use `:mounts` on a spec instead when you want the two to stay in sync.

  ### Find it again later

  Dockd keeps no memory of what it created; Docker does. So a fresh BEAM — a new
  `iex` session, a restarted app — finds everything by asking the daemon:

      > {:ok, instances} = Dockd.list(endpoint)
      > Enum.map(instances, & &1.name)
      ["dockd-scratch", "dockd-builder"]

      > {:ok, instance} = Dockd.get("scratch", endpoint)

  Nothing needs to have been saved between sessions, and there is no registry to
  get out of sync.

  ### Stop it, start it, check on it

  Stopping frees the memory and CPU without losing anything inside the box:

      > :ok = Dockd.stop(instance, endpoint)
      > {:ok, false} = Dockd.running?(instance, endpoint)
      > :ok = Dockd.start(instance, endpoint)

  A `%Dockd.Instance{}` you are holding is a snapshot from when you fetched it,
  so after a change like that, ask for a fresh one:

      > {:ok, instance} = Dockd.refresh(instance, endpoint)
      > instance.running?
      true

  When something is wrong, read the output or the raw Docker record:

      > {:ok, output} = Dockd.logs(instance, endpoint, tail: 50)
      > {:ok, raw} = Dockd.inspect(instance, endpoint)
      > raw["State"]["ExitCode"]
      0

  ### Throw it away

      > :ok = Dockd.destroy(instance, endpoint)

  That stops and removes the container. Destroying one that is already gone is
  fine, so cleanup code does not have to check first.

  File copies stage through `temp_root` and clean up after themselves, but a
  hard kill can leave a directory behind. To check and sweep:

      > {:ok, leftovers} = Dockd.list_temp_files(temp_root)
      > :ok = Dockd.delete_temp_files(temp_root)

  ### One-shot commands

  `shell_command/4` runs a single command and returns its output and
  exit code. Each call is independent — no shell state carries over
  between calls.

      > {:ok, %{output: _, running: false, exit_code: 0}} =
      ...>   Dockd.shell_command(instance, ["echo", "hello"], endpoint)

      # Fresh exec each time — `cd` in one call does not affect the next.
      > {:ok, %{exit_code: 0}} = Dockd.shell_command(instance, "cd /tmp", endpoint)
      > {:ok, %{output: "/\\n"}} = Dockd.shell_command(instance, "pwd", endpoint)

  ### Longer-term interactive shells

  When you need state to persist across commands (cwd, environment
  variables, an authenticated session), open a single shell with
  `open_shell/3` and thread the handle through `shell_send/3`. Close
  it with `close_shell/2` when done.

      > {:ok, shell} = Dockd.open_shell(instance, endpoint)
      > {:ok, {_, shell}} = Dockd.shell_send(shell, "cd /tmp")
      > {:ok, {"/tmp\\n", shell}} = Dockd.shell_send(shell, "pwd")
      > {:ok, {_, shell}} = Dockd.shell_send(shell, "export FOO=bar")
      > {:ok, {"bar\\n", shell}} = Dockd.shell_send(shell, "echo $FOO")
      > :ok = Dockd.close_shell(shell)

  Close the shell when you are done with it. It is a live exec session on the
  container, not something dockd cleans up for you.

  ## Specs from data

  A container is described by a `Dockd.Spec`. Build one in Elixir with
  `Dockd.Spec.new/3`, or from a plain map with `Dockd.Spec.from_map/1` — which is
  all a "package" is:

      {:ok, spec} =
        Dockd.Spec.from_map(%{
          instance_name: "webapp",
          image: "node:20-slim",
          shell: "/bin/bash"
        })

      {:ok, result} = Dockd.apply(spec, endpoint, false, %{}, temp_root)

  Keys are atoms, here and in every nested entry. Where that map comes from —
  a module attribute, a file you read, a database row — is yours to decide;
  dockd never goes looking for one. You did the loading and any interpolating,
  so what is in the map is what reaches Docker. `Dockd.Spec.from_map/1`
  documents the consequences.

  ## Lifecycle

    - `apply/6` — create a container from a `Dockd.Spec`. Returns a
      `Dockd.ApplyResult` carrying the resulting `Dockd.Instance` and any
      step results from provisioning.
    - `apply_image/7` — the same, building the spec from an image and an
      instance name.
    - `list/2` — enumerate every dockd-managed `Instance` currently on the
      daemon.
    - `get/3` — fetch one `Instance` by its instance name.
    - `start/3` / `stop/3` / `restart/3` — control the container without
      destroying it.
    - `destroy/3` — stop and remove an instance.

  ## Visibility

    - `running?/3` — boolean liveness check.
    - `logs/3` — fetch container stdout/stderr as a binary.
    - `inspect/3` — return the raw Docker inspect map (escape hatch for
      ports, networks, exit code, started_at, etc.).
    - `refresh/3` — re-fetch a fresh `Instance` from Docker after a state
      change.

  ## Operating on instances

    - `shell_command/4` — one-shot exec, captures combined stdout+stderr
      (as `:output`) and the exit code.
    - `open_shell/3` / `shell_send/3` / `close_shell/2` — persistent
      interactive shell, state preserved between commands.
    - `copy_to/5` — upload host files into an existing instance.

  ## Host-side staging

  Dockd writes copied files to a staging dir under the `temp_root` you pass
  before uploading them into containers. These functions report and clean up
  that staging dir, and each takes the root as its argument:

    - `list_temp_files/1`
    - `delete_temp_files/1` — deletes recursively, so it refuses `""`, a relative
      path, and `"/"`. The directory a destructive sweep targets has to be one
      the caller named.

  ## Options

  Beyond the required positional arguments, public functions take a trailing
  `opts` keyword list for genuinely optional caller context: `:api_version`,
  `:platform`, `:networks`, `:network_mode`, and `:container_staging_root` (the
  in-container directory a file copy stages through, `"/tmp"` by default). None
  of these survive on the container, and keys outside the set are ignored as in
  any keyword-option API.

  The daemon endpoint and `disk_mount_enabled` are deliberately *not* among them
  — they are positional, so they cannot be forgotten and silently defaulted.
  """

  alias Dockd.ApplyResult
  alias Dockd.Files
  alias Dockd.Instance
  alias Dockd.Provisioner
  alias Dockd.Spec

  @typedoc """
  The host environment bare-name `:env` entries resolve against.

  Always an explicit argument, never `System.get_env/0`: a spec can only reach
  the values the caller chose to hand it. `%{}` resolves nothing.
  """
  @type host_env :: %{optional(binary()) => binary()}

  @log_param_keys [:tail, :since, :until, :follow]
  @log_option_keys [:stdout, :stderr, :timestamps]

  @doc """
  Creates a Docker container from `spec` and returns the result.

  Takes a `%Dockd.Spec{}` and its four required runtime inputs:

    - `endpoint` — the Docker daemon, e.g. `"unix:///var/run/docker.sock"`
    - `disk_mount_enabled` — `true` permits host mounts, file copies and
      host-derived env; `false` strips them
    - `host_env` — the environment `:env` entries resolve against. `%{}` resolves
      nothing from the host
    - `temp_root` — absolute host directory to stage file copies in

  None of them has a default. `disk_mount_enabled` in particular used to treat an
  absent value as `true`, which meant forgetting it granted maximum host exposure.

  To build a spec from an image string, use `apply_image/7`, or `Dockd.Spec.new/3`
  followed by this function.

  ## Examples

      {:ok, spec} =
        Dockd.Spec.new("busybox:1.37.0", "smoke",
          shell: "/bin/sh",
          env: ["FOO=bar"],
          steps: [%{step_name: "workdir", cmd: ["mkdir", "-p", "/work"]}]
        )

      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply(spec, "unix:///var/run/docker.sock", false, %{}, System.tmp_dir!())

      # Failure path: the error may carry the partially-created instance so
      # the caller can clean up.
      {:ok, spec} =
        Dockd.Spec.new("busybox:1.37.0", "smoke",
          steps: [%{step_name: "fail", cmd: ["sh", "-c", "exit 1"]}]
        )

      case Dockd.apply(spec, endpoint, false, %{}, tmp) do
        {:ok, %Dockd.ApplyResult{instance: instance}} ->
          instance

        {:error, %ErrorMessage{details: %{instance: instance}}} ->
          Dockd.destroy(instance, endpoint)
      end
  """
  @spec apply(Spec.t(), binary(), boolean(), host_env(), Path.t(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, ErrorMessage.t()}
  def apply(%Spec{} = spec, endpoint, disk_mount_enabled, host_env, temp_root, opts \\ []) do
    Provisioner.run(spec, endpoint, disk_mount_enabled, host_env, temp_root, opts)
  end

  @doc """
  Builds a `Dockd.Spec` from `image` and `instance_name`, then applies it.

  The convenience form of `apply/6`. `instance_name` is positional because it is
  required — there is no auto-generated container name — and `image` cannot carry
  it as an option without the two being separable only by a lookup table.

  Spec options and caller options share the trailing keyword list;
  `Dockd.Spec.option_keys/0` decides the split.

  ## Examples

      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply_image("busybox:1.37.0", "smoke",
          "unix:///var/run/docker.sock", false, %{}, System.tmp_dir!(),
          shell: "/bin/sh"
        )
  """
  @spec apply_image(binary(), binary(), binary(), boolean(), host_env(), Path.t(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, ErrorMessage.t()}
  def apply_image(
        image,
        instance_name,
        endpoint,
        disk_mount_enabled,
        host_env,
        temp_root,
        opts \\ []
      ) do
    {spec_opts, call_opts} = Keyword.split(opts, Spec.option_keys())

    with {:ok, spec} <- Spec.new(image, instance_name, spec_opts) do
      Provisioner.run(spec, endpoint, disk_mount_enabled, host_env, temp_root, call_opts)
    end
  end

  @doc """
  Lists every dockd-managed `Instance` currently on the Docker daemon.

  Discovers containers by filtering on the marker label
  `org.dockd.instance=true`, then hydrates each one via
  `Docker.find_container/2`.

  ## Examples

      {:ok, instances} = Dockd.list("unix:///var/run/docker.sock")
      Enum.map(instances, & &1.name)
      #=> ["dockd-smoke", "dockd-builder"]
  """
  @spec list(binary(), keyword()) :: {:ok, [Instance.t()]} | {:error, ErrorMessage.t()}
  def list(endpoint, opts \\ []) do
    with {:ok, docker_options} <- Provisioner.docker_options_from(endpoint, opts) do
      marker = "#{Instance.marker_label()}=true"

      case Docker.list_containers(%{all: true}, [labels: [marker]] ++ docker_options) do
        {:ok, summaries} ->
          hydrate_each(summaries, docker_options, [])

        {:error, reason} ->
          {:error,
           ErrorMessage.not_found("failed to list Docker containers", %{
             phase: :discover,
             reason: reason
           })}
      end
    end
  end

  @doc """
  Fetches a single `Instance` by instance name.

  Accepts either the short name (`"smoke"`) or the full Docker container
  name (`"dockd-smoke"`).

  ## Examples

      {:ok, %Dockd.Instance{} = instance} = Dockd.get("smoke", endpoint)
      {:ok, %Dockd.Instance{} = instance} = Dockd.get("dockd-smoke", endpoint)

      case Dockd.get("not-here", endpoint) do
        {:ok, instance} -> instance
        {:error, %ErrorMessage{} = err} -> err
      end
  """
  @spec get(binary(), binary(), keyword()) :: {:ok, Instance.t()} | {:error, ErrorMessage.t()}
  def get(name, endpoint, opts \\ []) do
    with {:ok, docker_options} <- Provisioner.docker_options_from(endpoint, opts) do
      case Docker.find_container(Spec.prefix_name(name), docker_options) do
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
  end

  @doc """
  Stops and removes an instance.

  Accepts either an `Instance` struct or an instance name (short or
  prefixed). Already-stopped and already-removed containers are treated as
  success.

  A bare string is always read as an instance *name* and is prefixed with
  `dockd-` if it isn't already, so a raw container ID passed as a string will
  not match anything and — because a missing container counts as success —
  returns `:ok` without removing it. To destroy by container ID, pass the
  `%Dockd.Instance{}` struct, whose `:id` is used verbatim.

  ## Examples

      # By instance struct (typical when you've just created it).
      :ok = Dockd.destroy(instance, endpoint)

      # By short name, or by full container name.
      :ok = Dockd.destroy("smoke", endpoint)
      :ok = Dockd.destroy("dockd-smoke", endpoint)

      # Idempotent — destroying something that's already gone is :ok.
      :ok = Dockd.destroy("smoke", endpoint)
  """
  @spec destroy(Instance.t() | binary(), binary(), keyword()) :: :ok | {:error, ErrorMessage.t()}
  def destroy(instance_or_ref, endpoint, opts \\ [])

  def destroy(%Instance{id: id}, endpoint, opts) do
    Provisioner.destroy(id, endpoint, opts)
  end

  def destroy(ref, endpoint, opts) do
    Provisioner.destroy(Spec.prefix_name(ref), endpoint, opts)
  end

  @doc """
  Starts a stopped instance, leaving it in place.

  Idempotent — starting an already-running instance returns `:ok`.

  ## Examples

      :ok = Dockd.start(instance, endpoint)
      :ok = Dockd.start("smoke", endpoint)
  """
  @spec start(Instance.t() | binary(), binary(), keyword()) :: :ok | {:error, ErrorMessage.t()}
  def start(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, docker_options}} <- resolve_ref(instance_or_ref, endpoint, opts) do
      case Docker.start_container(ref, docker_options) do
        {:ok, _} ->
          :ok

        {:error, %{status: 304}} ->
          :ok

        {:error, reason} ->
          {:error,
           ErrorMessage.bad_gateway("failed to start Docker container", %{
             phase: :lifecycle,
             reason: reason
           })}
      end
    end
  end

  @doc """
  Stops a running instance without removing it.

  Idempotent — stopping an already-stopped instance returns `:ok`.

  ## Examples

      :ok = Dockd.stop(instance, endpoint)
      :ok = Dockd.stop("smoke", endpoint)
  """
  @spec stop(Instance.t() | binary(), binary(), keyword()) :: :ok | {:error, ErrorMessage.t()}
  def stop(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, docker_options}} <- resolve_ref(instance_or_ref, endpoint, opts) do
      case Docker.stop_container(ref, docker_options) do
        {:ok, _} ->
          :ok

        {:error, %{status: 304}} ->
          :ok

        {:error, reason} ->
          {:error,
           ErrorMessage.bad_gateway("failed to stop Docker container", %{
             phase: :lifecycle,
             reason: reason
           })}
      end
    end
  end

  @doc """
  Stops then starts an instance.

  Equivalent to `stop/3` followed by `start/3`. If the stop step fails
  the start step is skipped and the stop error is returned.

  ## Examples

      :ok = Dockd.restart(instance, endpoint)
  """
  @spec restart(Instance.t() | binary(), binary(), keyword()) :: :ok | {:error, ErrorMessage.t()}
  def restart(instance_or_ref, endpoint, opts \\ []) do
    with :ok <- stop(instance_or_ref, endpoint, opts) do
      start(instance_or_ref, endpoint, opts)
    end
  end

  @doc """
  Returns `true` when the instance's container is running on the daemon.

  Cheap — a single Docker inspect, no exec.

  ## Examples

      {:ok, true} = Dockd.running?(instance, endpoint)
      {:ok, false} = Dockd.running?("smoke", endpoint)
  """
  @spec running?(Instance.t() | binary(), binary(), keyword()) ::
          {:ok, boolean()} | {:error, ErrorMessage.t()}
  def running?(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, docker_options}} <- resolve_ref(instance_or_ref, endpoint, opts) do
      {:ok, Docker.container_running?(ref, docker_options)}
    end
  end

  @doc """
  Fetches the instance's container logs as a binary (stdout + stderr,
  demuxed).

  Log filter keys are read out of `opts` and forwarded to Docker:

    - `:tail` — number of lines (or `"all"`)
    - `:since` / `:until` — Unix timestamps
    - `:follow` — boolean (note: streaming is not supported by the
      underlying client, leave unset for one-shot reads)
    - `:timestamps` — boolean
    - `:stdout` / `:stderr` — booleans (default both `true`)

  Other keys in `opts` are treated as the usual per-call Docker options.

  ## Examples

      {:ok, logs} = Dockd.logs(instance, endpoint)
      {:ok, tail} = Dockd.logs(instance, endpoint, tail: 100, timestamps: true)
      {:ok, stderr} = Dockd.logs("smoke", endpoint, stdout: false, stderr: true)
  """
  @spec logs(Instance.t() | binary(), binary(), keyword()) ::
          {:ok, binary()} | {:error, ErrorMessage.t()}
  def logs(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, docker_options}} <- resolve_ref(instance_or_ref, endpoint, opts) do
      {params, log_options} = split_log_opts(opts)

      case Docker.container_logs(ref, params, log_options ++ docker_options) do
        {:ok, logs} ->
          {:ok, logs}

        {:error, reason} ->
          {:error,
           ErrorMessage.not_found("failed to read Docker container logs", %{
             phase: :discover,
             reason: reason
           })}
      end
    end
  end

  @doc """
  Returns the raw Docker `inspect` map for an instance.

  Use this as an escape hatch when you need state that isn't on
  `%Dockd.Instance{}` — port bindings, network IPs, exit code, started
  timestamps, restart policy, etc.

  ## Examples

      {:ok, raw} = Dockd.inspect(instance, endpoint)
      raw["State"]["StartedAt"]
      raw["NetworkSettings"]["IPAddress"]
  """
  @spec inspect(Instance.t() | binary(), binary(), keyword()) ::
          {:ok, map()} | {:error, ErrorMessage.t()}
  def inspect(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, docker_options}} <- resolve_ref(instance_or_ref, endpoint, opts) do
      case Docker.find_container(ref, docker_options) do
        {:ok, body} ->
          {:ok, body}

        {:error, reason} ->
          {:error,
           ErrorMessage.not_found("failed to inspect Docker container", %{
             phase: :discover,
             reason: reason
           })}
      end
    end
  end

  @doc """
  Re-fetches an instance from Docker, returning a fresh `%Dockd.Instance{}`.

  Useful after `start/3`, `stop/3`, or `restart/3` to refresh the
  `:running?` field (and anything else hydrated from Docker inspect).

  ## Examples

      {:ok, fresh} = Dockd.refresh(instance, endpoint)
      {:ok, fresh} = Dockd.refresh("smoke", endpoint)
  """
  @spec refresh(Instance.t() | binary(), binary(), keyword()) ::
          {:ok, Instance.t()} | {:error, ErrorMessage.t()}
  def refresh(instance_or_ref, endpoint, opts \\ [])

  def refresh(%Instance{} = instance, endpoint, opts) do
    get(Instance.short_name(instance), endpoint, opts)
  end

  def refresh(ref, endpoint, opts) do
    get(ref, endpoint, opts)
  end

  @doc """
  Runs `command` inside the instance and returns the combined output plus
  exit code. `command` may be a string (run with the instance's shell) or
  an argv list (run verbatim).

  ## Examples

      # String form — invoked through the instance's configured shell.
      # `:output` is stdout and stderr combined into one binary.
      {:ok, %{output: "hello\\n", exit_code: 0}} =
        Dockd.shell_command(instance, "echo hello", endpoint)

      # Argv form — exec'd verbatim, no shell parsing.
      {:ok, %{exit_code: 0}} = Dockd.shell_command(instance, ["true"], endpoint)
      {:ok, %{exit_code: 3}} =
        Dockd.shell_command(instance, ["sh", "-c", "exit 3"], endpoint)

      # Also accepts an instance name instead of the struct.
      {:ok, _} = Dockd.shell_command("smoke", "uname -a", endpoint)
  """
  @spec shell_command(Instance.t() | binary(), [binary()] | binary(), binary(), keyword()) ::
          {:ok, Docker.exec_result()} | {:error, ErrorMessage.t()}
  def shell_command(instance_or_ref, command, endpoint, opts \\ []) do
    with {:ok, {ref, instance_opts}} <- resolve_ref(instance_or_ref, endpoint, opts) do
      case Docker.Terminal.run_with_status(ref, command, instance_opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error,
           ErrorMessage.bad_gateway("failed to run command in Docker container", %{
             phase: :setup,
             reason: reason
           })}
      end
    end
  end

  @doc """
  Opens a persistent interactive shell on the instance.

  Returns a `t:Docker.Terminal.handle/0` (the container ref) that
  preserves shell state (cwd, env, shell variables) across
  `shell_send/3` calls. The same handle is threaded back through
  `shell_send/3` and finally `close_shell/2`. Pair every successful
  `open_shell/3` with `close_shell/2`.

  When no `:shell` option is given, the session program defaults to the
  instance's configured shell (`Instance.shell`, i.e. the container's
  interactive-shell program). Pass `shell: argv` to override. If neither is
  available the session falls back to `/bin/sh`.

  ## Examples

      {:ok, shell} = Dockd.open_shell(instance, endpoint)
      {:ok, {_, shell}} = Dockd.shell_send(shell, "cd /tmp")
      {:ok, {"/tmp\\n", shell}} = Dockd.shell_send(shell, "pwd")
      :ok = Dockd.close_shell(shell)

      # Also accepts an instance name.
      {:ok, shell} = Dockd.open_shell("smoke", endpoint)
  """
  @spec open_shell(Instance.t() | binary(), binary(), keyword()) ::
          {:ok, Docker.Terminal.handle()} | {:error, ErrorMessage.t()}
  def open_shell(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, instance_opts}} <- resolve_ref(instance_or_ref, endpoint, opts),
         {:ok, configured} <- configured_shell_for(instance_or_ref, endpoint, opts) do
      open_opts = instance_opts ++ resolve_shell_arg(opts, configured)

      case Docker.Terminal.open(ref, open_opts) do
        {:ok, _session} ->
          {:ok, ref}

        {:error, reason} ->
          {:error,
           ErrorMessage.bad_gateway("failed to open a shell in Docker container", %{
             phase: :setup,
             reason: reason
           })}
      end
    end
  end

  # Decides the `:shell` option to add when opening a shell into an instance:
  #
  #   1. an explicit `opts[:shell]` wins, so nothing is added (`[]`)
  #   2. otherwise the instance's `configured` program is used, argv-wrapped
  #   3. otherwise nothing is added and Docker falls back to `/bin/sh`
  @spec resolve_shell_arg(keyword(), binary() | nil) :: keyword()
  defp resolve_shell_arg(opts, configured) do
    if is_binary(configured) and not Keyword.has_key?(opts, :shell),
      do: [shell: [configured]],
      else: []
  end

  @doc """
  Sends `command` to a shell opened with `open_shell/2` and returns the
  output plus the terminal handle to thread into the next call.

  ## Examples

      {:ok, shell} = Dockd.open_shell("smoke")

      # Successful command — stdout is returned as a binary.
      {:ok, {"/\\n", shell}} = Dockd.shell_send(shell, "pwd")

      # Commands that produce both streams come back as {stdout, stderr}.
      {:ok, {{_stdout, _stderr}, shell}} =
        Dockd.shell_send(shell, "echo out; echo err 1>&2")

      # State persists across calls in the same shell session.
      {:ok, {_, shell}} = Dockd.shell_send(shell, "export FOO=bar")
      {:ok, {"bar\\n", shell}} = Dockd.shell_send(shell, "echo $FOO")

      :ok = Dockd.close_shell(shell)

  On failure the handle is **not** in the error tuple — it is at
  `details.shell`, so the session can still be closed or retried:

      {:error, %ErrorMessage{details: %{shell: shell}}} = Dockd.shell_send(shell, "pwd")
      :ok = Dockd.close_shell(shell)
  """
  @spec shell_send(Docker.Terminal.handle(), iodata(), keyword()) ::
          {:ok, {binary() | {binary(), binary()}, Docker.Terminal.handle()}}
          | {:error, ErrorMessage.t()}
  def shell_send(shell, command, opts \\ []) do
    case Docker.Terminal.command(shell, command, opts) do
      {:ok, _} = ok ->
        ok

      # `Docker.Terminal.command/3` always hands the handle back alongside the
      # reason. It moves to `details` so every public function fails the same
      # shape, but it still has to survive: without it the caller cannot close
      # the session it just failed to write to.
      {:error, {reason, handle}} ->
        {:error,
         ErrorMessage.bad_gateway("failed to send command to shell", %{
           phase: :setup,
           reason: reason,
           shell: handle
         })}
    end
  end

  @doc """
  Closes a shell handle previously returned by `open_shell/2`.

  Idempotent — safe to call on an already-closed handle.

  ## Examples

      {:ok, shell} = Dockd.open_shell("smoke")
      {:ok, {_, shell}} = Dockd.shell_send(shell, "echo hi")
      :ok = Dockd.close_shell(shell)
  """
  @spec close_shell(Docker.Terminal.handle(), keyword()) :: :ok
  def close_shell(shell, _opts \\ []) do
    Docker.Terminal.close(shell)
  end

  @doc """
  Copies host files or directories into an existing instance.

  `copies` is a list of `%{src:, dest:}` maps — the same shape accepted by
  `Dockd.Spec`'s `:copy` field, with `src` required to be an absolute path. Uses
  the same tar + put_archive pipeline that `apply/6` uses at create time, so it
  needs the same `temp_root` to stage in.

  ## Examples

      :ok =
        Dockd.copy_to(
          instance,
          [
            %{src: "/srv/config/app.env", dest: "/etc/app/app.env"},
            %{src: "/srv/scripts", dest: "/opt/scripts"}
          ],
          System.tmp_dir!(),
          endpoint
        )
  """
  @spec copy_to(Instance.t() | binary(), [map()], Path.t(), binary(), keyword()) ::
          :ok | {:error, ErrorMessage.t()}
  def copy_to(instance_or_ref, copies, temp_root, endpoint, opts \\ []) do
    with {:ok, container_id, docker_options} <-
           resolve_container_id(instance_or_ref, endpoint, opts) do
      Files.copy_files(copies, container_id, temp_root, docker_options, opts)
    end
  end

  @doc """
  Lists the staging directories dockd has left under `temp_root` on the local
  node.

  These are created during file copies when preparing data
  for upload into a container. They are usually cleaned up automatically; this
  function exposes whatever is left.

  `temp_root` is the same directory you passed to `apply/6` or `copy_to/5`.
  """
  @spec list_temp_files(Path.t()) :: {:ok, [Path.t()]}
  def list_temp_files(temp_root) do
    {:ok, Files.list_temp_files(temp_root)}
  end

  @doc """
  Deletes every staging directory dockd has left under `temp_root` on the local
  node, leaving `temp_root` itself in place.

  This deletes recursively, so `temp_root` is a required argument rather than a
  value read from the environment: the directory a destructive sweep targets must
  be one the caller named. `""`, a relative path, and `"/"` are refused.
  """
  @spec delete_temp_files(Path.t()) :: :ok | {:error, ErrorMessage.t()}
  def delete_temp_files(temp_root) do
    Files.delete_temp_files(temp_root)
  end

  # ---------------------------------------------------------------------------

  # Reads the instance's configured program. Avoids I/O when we already hold the
  # hydrated struct; auto-hydrates a bare ref via get/3, and reports a failed
  # lookup rather than falling back to a default program. `resolve_shell_arg/2`
  # decides whether the result is used — an explicit `opts[:shell]` wins.
  defp configured_shell_for(%Instance{shell: shell}, _endpoint, _opts), do: {:ok, shell}

  defp configured_shell_for(ref, endpoint, opts) do
    with {:ok, %Instance{shell: shell}} <- get(ref, endpoint, opts) do
      {:ok, shell}
    end
  end

  defp resolve_ref(%Instance{id: id}, endpoint, opts) do
    with {:ok, docker_options} <- Provisioner.docker_options_from(endpoint, opts) do
      {:ok, {id, docker_options}}
    end
  end

  defp resolve_ref(ref, endpoint, opts) do
    with {:ok, docker_options} <- Provisioner.docker_options_from(endpoint, opts) do
      {:ok, {Spec.prefix_name(ref), docker_options}}
    end
  end

  defp resolve_container_id(%Instance{id: id}, endpoint, opts) do
    with {:ok, docker_options} <- Provisioner.docker_options_from(endpoint, opts) do
      {:ok, id, docker_options}
    end
  end

  defp resolve_container_id(ref, endpoint, opts) do
    with {:ok, docker_options} <- Provisioner.docker_options_from(endpoint, opts) do
      lookup_container_id(ref, docker_options)
    end
  end

  defp lookup_container_id(ref, docker_options) do
    case Docker.find_container(Spec.prefix_name(ref), docker_options) do
      {:ok, %{"Id" => id}} ->
        {:ok, id, docker_options}

      {:error, reason} ->
        {:error,
         ErrorMessage.not_found("failed to inspect Docker container", %{
           phase: :discover,
           reason: reason
         })}
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
    id = Map.fetch!(summary, "Id")

    case Docker.find_container(id, docker_options) do
      {:ok, body} ->
        hydrate_each(rest, docker_options, [Instance.from_inspect(body) | acc])

      {:error, reason} ->
        {:error,
         ErrorMessage.not_found("failed to inspect Docker container", %{
           phase: :discover,
           reason: reason
         })}
    end
  end
end
