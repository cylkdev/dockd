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

  With a Docker daemon running locally, apply an installed package by name and
  you have a live instance:

      > {:ok, %Dockd.ApplyResult{instance: instance}} = Dockd.apply_package("webapp")

  ### One-shot commands

  `shell_command/3` runs a single command and returns its output and
  exit code. Each call is independent — no shell state carries over
  between calls.

      > {:ok, %{output: _, running: false, exit_code: 0}} =
      ...>   Dockd.shell_command(instance, ["echo", "hello"])

      # Fresh exec each time — `cd` in one call does not affect the next.
      > {:ok, %{exit_code: 0}} = Dockd.shell_command(instance, "cd /tmp")
      > {:ok, %{output: "/\\n"}} = Dockd.shell_command(instance, "pwd")

  ### Longer-term interactive shells

  When you need state to persist across commands (cwd, environment
  variables, an authenticated session), open a single shell with
  `open_shell/2` and thread the handle through `shell_send/3`. Close
  it with `close_shell/2` when done.

      > {:ok, shell} = Dockd.open_shell(instance)
      > {:ok, {_, shell}} = Dockd.shell_send(shell, "cd /tmp")
      > {:ok, {"/tmp\\n", shell}} = Dockd.shell_send(shell, "pwd")
      > {:ok, {_, shell}} = Dockd.shell_send(shell, "export FOO=bar")
      > {:ok, {"bar\\n", shell}} = Dockd.shell_send(shell, "echo $FOO")
      > :ok = Dockd.close_shell(shell)

      > :ok = Dockd.destroy(instance)

  For a shell a *human* drives, in a real terminal window with its own TTY, see
  `Dockd.Shell` instead — `open_shell/2` is the programmatic form.

  `apply_package/2` resolves package names through the configured packages
  root and runs the full
  provisioning pipeline (pull or build, create, start, fetch repos,
  copy files, run setup steps). The returned `Dockd.Instance` is a
  view of the live container — pass it (or its name) to any other
  function in this module. See "Packages" below for the full
  resolution rules and how to install additional package sets from
  git.

  ## Lifecycle

    - `apply/2` — create a container from a `Dockd.Spec`. Returns a
      `Dockd.ApplyResult` carrying the resulting `Dockd.Instance` and any
      step results from provisioning.
    - `apply_package/2` — same as `apply/2` but loads the `Spec` from a
      JSON package file (see "Packages" below).
    - `list/1` — enumerate every dockd-managed `Instance` currently on the
      daemon.
    - `get/2` — fetch one `Instance` by its instance name.
    - `start/2` / `stop/2` / `restart/2` — control the container without
      destroying it.
    - `destroy/2` — stop and remove an instance.

  ## Packages on disk

    - `install_packages/2` — install a package set from a git repository or a
      local directory.
    - `new_package/2` — scaffold a new package's files on disk.
    - `list_packages/1` — enumerate installed packages.

  ## Packages

  A package is a directory under the configured packages root containing a
  `package.json` (the serialized `Dockd.Spec`: image, shell, env,
  mounts, repos, copies, setup steps, etc.) plus any supporting files
  the spec references — typically a `Dockerfile` for `build`-based
  packages. The directory name is the package's identity.

  `apply_package/2` resolves its reference as follows:

    - any string ending in `.json` is treated as a literal file path
    - any other string containing `/` is treated as a package directory
      and resolves to `<dir>/package.json`
    - any other string is resolved against
      `<packages_root>/<name>/package.json`

  The packages root is `opts[:packages_path]`, else `DOCKD_PACKAGES_PATH`, else
  `config :dockd, packages_path: ...`, else `~/.dockd/packages`.

  Packages generated or installed into the package root can be applied by
  basename:

      # Resolves to <packages_root>/webapp/package.json
      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply_package("webapp")

      # Same, with per-call Docker options.
      {:ok, result} =
        Dockd.apply_package("webapp", socket: "/var/run/docker.sock")

      # Explicit directory.
      {:ok, result} = Dockd.apply_package("./my-stack")

      # Explicit file path.
      {:ok, result} = Dockd.apply_package("./my-stack/package.json")

  Additional packages are installed with `install_packages/2`, from either a
  git repository or a local directory. Every `<source>/packages/<name>/`
  directory that contains a `package.json` is copied into
  `<packages_root>/<name>/`, after which the package can be applied by name.
  `list_packages/1` enumerates what is currently installed.

      {:ok, ["webapp"]} = Dockd.install_packages("github.com/me/recipes")
      {:ok, ["webapp"]} = Dockd.install_packages("./my-recipes")

      [%{name: "webapp"}] = Dockd.list_packages()

  ## Visibility

    - `running?/2` — boolean liveness check.
    - `logs/2` — fetch container stdout/stderr as a binary.
    - `inspect/2` — return the raw Docker inspect map (escape hatch for
      ports, networks, exit code, started_at, etc.).
    - `refresh/2` — re-fetch a fresh `Instance` from Docker after a state
      change.

  ## Operating on instances

    - `shell_command/3` — one-shot exec, captures combined stdout+stderr
      (as `:output`) and the exit code.
    - `open_shell/2` / `shell_send/3` / `close_shell/2` — persistent
      interactive shell, state preserved between commands.
    - `copy_to/3` — upload host files into an existing instance.

  ## Host-side staging

  Dockd writes copied files and cloned repos to a staging dir under
  `<system_tmp>/dockd/` before uploading them into containers. These
  functions report and clean up that local staging dir:

    - `list_temp_files/1`
    - `delete_temp_files/1`

  And the broader, extension-friendly aggregate:

    - `info/1` — returns `%{temp_files: %{...}}` today, more keys later.

  All public functions accept a per-call `opts` keyword list for caller
  runtime context: `:socket`, `:host`, `:api_version`, `:platform`,
  `:networks`, `:network_mode`, and the policy flag `:disk_mount_enabled`.
  None of these survive on the container.
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
  Creates a Docker container from `spec_or_image` and returns the result.

  Two input shapes are accepted:

    - a `%Dockd.Spec{}` — used as-is
    - an image string plus a keyword list of spec options (the Elixir-native
      shape; equivalent to calling `Dockd.Spec.from_opts/2` first)

  An `:instance_name` is always required — there is no auto-generated container name.
  Calling `apply/2` with an image string and no `:instance_name` returns a `:validate`
  error.

  Per-call options (Docker connection settings and `:disk_mount_enabled`)
  and spec options share the same flat keyword list as the second
  argument. `Dockd.Spec.option_keys/0` decides the split: any key it
  claims is routed into `Spec.from_opts/2`, anything else is treated as
  a per-call option. Unknown keys are rejected.

  ## Examples

      # Image plus spec options.
      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply("busybox:1.37.0",
          instance_name: "smoke",
          shell: "/bin/sh",
          env: ["FOO=bar"],
          steps: [%{step_name: "workdir", cmd: ["mkdir", "-p", "/work"]}]
        )

      # :instance_name is required.
      {:error, %Dockd.Error{phase: :validate}} = Dockd.apply("busybox:1.37.0")

      # Spec options and per-call options share one flat keyword list.
      {:ok, result} =
        Dockd.apply("busybox:1.37.0",
          instance_name: "smoke",
          shell: "/bin/sh",
          socket: "/var/run/docker.sock"
        )

      # A pre-built %Dockd.Spec{} struct — opts is the per-call options list.
      spec = Dockd.Spec.from_opts("busybox:1.37.0", instance_name: "smoke", shell: "/bin/sh")
      {:ok, result} = Dockd.apply(spec, socket: "/var/run/docker.sock")

      # Failure path: the error may carry the partially-created instance so
      # the caller can clean up.
      steps = [%{step_name: "fail", cmd: ["sh", "-c", "exit 1"]}]

      case Dockd.apply("busybox:1.37.0", instance_name: "smoke", steps: steps) do
        {:ok, %Dockd.ApplyResult{instance: instance}} ->
          instance

        {:error, %Dockd.Error{instance: instance}} when not is_nil(instance) ->
          Dockd.destroy(instance)
      end
  """
  @spec apply(Spec.t() | binary(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
  def apply(spec_or_image, opts \\ [])

  def apply(%Spec{} = spec, opts) when is_list(opts) do
    with :ok <- check_call_opts(opts) do
      Provisioner.run(spec, opts)
    end
  end

  def apply(image, opts) when is_binary(image) and is_list(opts) do
    {spec_opts, call_opts} = Keyword.split(opts, Spec.option_keys())

    with :ok <- check_call_opts(call_opts),
         :ok <- check_spec_instance_name(spec_opts) do
      spec = Spec.from_opts(image, spec_opts)
      Provisioner.run(spec, call_opts)
    end
  end

  @doc """
  Loads a JSON package file and applies it.

  Resolves the package reference as described in the "Packages" section:

    - `<name>.json` or any path containing `/` is treated as a file path
    - any other string is resolved against `<packages_root>/<name>/package.json`

  The document is read, parsed, environment-interpolated against
  `System.get_env/0`, and normalized into spec attributes. The package must
  declare a non-empty `"name"`.

  ## Examples

      # Resolved against <packages_root>/elixir/package.json.
      {:ok, %Dockd.ApplyResult{instance: instance}} = Dockd.apply_package("elixir")

      # Explicit path — anything with `/` or ending in `.json`.
      {:ok, result} = Dockd.apply_package("./packages/my-stack.json")
      {:ok, result} = Dockd.apply_package("/abs/path/stack.json")

      # With per-call Docker options.
      {:ok, result} =
        Dockd.apply_package("elixir", socket: "/var/run/docker.sock")
  """
  @spec apply_package(binary(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
  def apply_package(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    path = Packages.resolve_path(ref, opts)

    with {:ok, spec} <- load_package_spec(path) do
      Provisioner.run(spec, opts)
    end
  end

  @doc """
  Installs packages from a git repository or a local directory into the
  configured packages root.

  `ref` selects the source: an existing directory on the host installs from
  that directory, anything else is treated as a git URL and cloned with the
  host `git` binary. Either way, every `<source>/packages/<name>/` directory
  containing a `package.json` is copied into `<packages_root>/<name>/`, and an
  existing target directory is replaced.

  A git URL can be anything `git clone` accepts (HTTPS, SSH, or the
  `github.com/user/repo` shorthand). A source with no top-level `packages/`
  directory is a `:fetch` error.

  Options:

    - `:ref` — git branch or tag to clone. Ignored when installing from a
      local directory, which is used exactly as it is on disk.
    - `:packages_path` — override the configured packages root.

  Returns `{:ok, [name]}` with the installed package names.

  ## Examples

      # From a remote repository.
      {:ok, ["foo", "bar"]} =
        Dockd.install_packages("https://github.com/me/recipes")

      {:ok, _} =
        Dockd.install_packages("github.com/me/recipes", ref: "v1.2.0")

      # From a local checkout — anything that is an existing directory.
      {:ok, ["foo", "bar"]} = Dockd.install_packages("./my-recipes")
  """
  @spec install_packages(binary(), keyword()) ::
          {:ok, [binary()]} | {:error, Error.t()}
  def install_packages(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    if File.dir?(ref) do
      Packages.install_from_path(ref, opts)
    else
      Packages.install_from_git(ref, opts)
    end
  end

  @doc """
  Scaffolds a new package into `dir`, so you never have to hand-write
  `package.json` and `Dockerfile`.

  `dir` **is** the package directory. The generated package always builds its
  own image from the generated `Dockerfile`, so `:image` is the tag that build
  produces and `:from` is the Dockerfile's base image.

  Only the keys you pass are written. Refuses to touch an existing directory
  unless `force: true`, and validates before writing anything — a rejected call
  leaves nothing behind. See `Dockd.Packages.new/2` for the full option list.

  ## Examples

      # Minimal — instance name from the directory, image defaults to
      # dockd-greeter:latest, Dockerfile defaults to FROM debian:trixie.
      {:ok, %{files: _}} = Dockd.new_package("./greeter")

      # Into a shareable package set, ready for install_packages/2.
      {:ok, %{instance_name: "greeter"}} =
        Dockd.new_package("./my-recipes/packages/greeter",
          image: "dockd-greeter:1",
          from: "busybox:1.37.0",
          shell: "/bin/sh",
          env: [{"API_KEY", optional: true}],
          steps: [%{step_name: "verify", cmd: ["sh", "-c", "test -f /etc/greeting"]}]
        )

      {:ok, ["greeter"]} = Dockd.install_packages("./my-recipes")
  """
  @spec new_package(Path.t(), keyword()) ::
          {:ok,
           %{
             instance_name: binary(),
             path: Path.t(),
             files: [Path.t()],
             overwrote?: boolean()
           }}
          | {:error, Error.t()}
  def new_package(dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    Packages.new(dir, opts)
  end

  @doc """
  Lists every package installed under the configured packages root.

  A subdirectory counts as an installed package when it contains a readable
  `package.json`. Each entry is a map with `:name`, `:path`, and `:spec`,
  sorted by name.

  `:spec` is itself a result tuple — `{:ok, %Dockd.Spec{}}` or
  `{:error, %Dockd.Error{}}` — so one malformed `package.json` surfaces its own
  parse error instead of hiding every other installed package.

  Never fails: an unreadable or missing packages root returns `[]`.

  Note that specs are parsed without `${VAR}` interpolation, so this is safe to
  call for metadata (image, shell, description) even when the host environment
  does not define the variables a package references.

  ## Examples

      [%{name: "webapp", path: path, spec: {:ok, spec}}] = Dockd.list_packages()

      # Against a specific packages root.
      [] = Dockd.list_packages(packages_path: "/tmp/empty")
  """
  @spec list_packages(keyword()) :: [
          %{
            name: binary(),
            path: Path.t(),
            spec: {:ok, Spec.t()} | {:error, Error.t()}
          }
        ]
  def list_packages(opts \\ []) when is_list(opts) do
    Packages.list(opts)
  end

  @doc """
  Lists every dockd-managed `Instance` currently on the Docker daemon.

  Discovers containers by filtering on the marker label
  `org.dockd.instance=true`, then hydrates each one via
  `Docker.find_container/2`.

  ## Examples

      {:ok, instances} = Dockd.list()
      Enum.map(instances, & &1.name)
      #=> ["dockd-smoke", "dockd-builder"]

      # Against a specific Docker daemon.
      {:ok, instances} = Dockd.list(socket: "/var/run/docker.sock")
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
  Fetches a single `Instance` by instance name.

  Accepts either the short name (`"smoke"`) or the full Docker container
  name (`"dockd-smoke"`).

  ## Examples

      {:ok, %Dockd.Instance{} = instance} = Dockd.get("smoke")
      {:ok, %Dockd.Instance{} = instance} = Dockd.get("dockd-smoke")

      case Dockd.get("not-here") do
        {:ok, instance} -> instance
        {:error, %Dockd.Error{} = err} -> err
      end
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
      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply("busybox:1.37.0", instance_name: "smoke")

      :ok = Dockd.destroy(instance)

      # By short name.
      :ok = Dockd.destroy("smoke")

      # By full container name.
      :ok = Dockd.destroy("dockd-smoke")

      # Idempotent — destroying something that's already gone is :ok.
      :ok = Dockd.destroy("smoke")
      :ok = Dockd.destroy("smoke")
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
  Starts a stopped instance, leaving it in place.

  Idempotent — starting an already-running instance returns `:ok`.

  ## Examples

      :ok = Dockd.start(instance)
      :ok = Dockd.start("smoke")
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
  Stops a running instance without removing it.

  Idempotent — stopping an already-stopped instance returns `:ok`.

  ## Examples

      :ok = Dockd.stop(instance)
      :ok = Dockd.stop("smoke")
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
  Stops then starts an instance.

  Equivalent to `stop/2` followed by `start/2`. If the stop step fails
  the start step is skipped and the stop error is returned.

  ## Examples

      :ok = Dockd.restart(instance)
  """
  @spec restart(Instance.t() | binary(), keyword()) :: :ok | {:error, Error.t()}
  def restart(instance_or_ref, opts \\ []) do
    with :ok <- stop(instance_or_ref, opts) do
      start(instance_or_ref, opts)
    end
  end

  @doc """
  Returns `true` when the instance's container is running on the daemon.

  Cheap — a single Docker inspect, no exec.

  ## Examples

      {:ok, true} = Dockd.running?(instance)
      {:ok, false} = Dockd.running?("smoke")
  """
  @spec running?(Instance.t() | binary(), keyword()) :: {:ok, boolean()}
  def running?(instance_or_ref, opts \\ []) do
    {ref, docker_options} = resolve_ref(instance_or_ref, opts)
    {:ok, Docker.container_running?(ref, docker_options)}
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

  Other keys in `opts` are treated as the usual per-call connection
  options (`:socket`, `:host`, …).

  ## Examples

      {:ok, logs} = Dockd.logs(instance)
      {:ok, tail} = Dockd.logs(instance, tail: 100, timestamps: true)
      {:ok, stderr} = Dockd.logs("smoke", stdout: false, stderr: true)
  """
  @spec logs(Instance.t() | binary(), keyword()) :: Docker.result(binary())
  def logs(instance_or_ref, opts \\ []) do
    {ref, docker_options} = resolve_ref(instance_or_ref, opts)
    {params, log_options} = split_log_opts(opts)
    Docker.container_logs(ref, params, log_options ++ docker_options)
  end

  @doc """
  Returns the raw Docker `inspect` map for an instance.

  Use this as an escape hatch when you need state that isn't on
  `%Dockd.Instance{}` — port bindings, network IPs, exit code, started
  timestamps, restart policy, etc.

  ## Examples

      {:ok, raw} = Dockd.inspect(instance)
      raw["State"]["StartedAt"]
      raw["NetworkSettings"]["IPAddress"]
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
  Re-fetches an instance from Docker, returning a fresh `%Dockd.Instance{}`.

  Useful after `start/2`, `stop/2`, or `restart/2` to refresh the
  `:running?` field (and anything else hydrated from Docker inspect).

  ## Examples

      {:ok, fresh} = Dockd.refresh(instance)
      {:ok, fresh} = Dockd.refresh("smoke")
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
  Runs `command` inside the instance and returns the combined output plus
  exit code. `command` may be a string (run with the instance's shell) or
  an argv list (run verbatim).

  ## Examples

      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply("busybox:1.37.0", instance_name: "smoke", shell: "/bin/sh")

      # String form — invoked through the instance's configured shell.
      # `:output` is stdout and stderr combined into one binary.
      {:ok, %{output: "hello\\n", exit_code: 0}} =
        Dockd.shell_command(instance, "echo hello")

      # Argv form — exec'd verbatim, no shell parsing.
      {:ok, %{exit_code: 0}} = Dockd.shell_command(instance, ["true"])
      {:ok, %{exit_code: 3}} =
        Dockd.shell_command(instance, ["sh", "-c", "exit 3"])

      # Also accepts an instance name instead of the struct.
      {:ok, _} = Dockd.shell_command("smoke", "uname -a")
  """
  @spec shell_command(Instance.t() | binary(), [binary()] | binary(), keyword()) ::
          Docker.result(Docker.exec_result())
  def shell_command(instance_or_ref, command, opts \\ []) do
    {ref, instance_opts} = resolve_ref(instance_or_ref, opts)
    Docker.Terminal.run_with_status(ref, command, instance_opts)
  end

  @doc """
  Opens a persistent interactive shell on the instance.

  Returns a `Docker.Terminal.handle/0` (the container ref) that
  preserves shell state (cwd, env, shell variables) across
  `shell_send/3` calls. The same handle is threaded back through
  `shell_send/3` and finally `close_shell/2`. Pair every successful
  `open_shell/2` with `close_shell/2`.

  When no `:shell` option is given, the session program defaults to the
  instance's configured shell (`Instance.shell`, i.e. the container's
  interactive-shell program). Pass `shell: argv` to override. If neither is
  available the session falls back to `/bin/sh`.

  ## Examples

      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply("busybox:1.37.0", shell: "/bin/sh")

      {:ok, shell} = Dockd.open_shell(instance)
      {:ok, {_, shell}} = Dockd.shell_send(shell, "cd /tmp")
      {:ok, {"/tmp\\n", shell}} = Dockd.shell_send(shell, "pwd")
      :ok = Dockd.close_shell(shell)

      # Also accepts an instance name.
      {:ok, shell} = Dockd.open_shell("smoke")
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

  @doc """
  Decides the `:shell` option to add when opening a shell into an instance.

  Exposed because `open_shell/2`'s shell precedence is worth being able to
  reason about (and test) on its own. Returns the keyword list to append to the
  Docker options — either `[shell: [program]]` or `[]`.

  Precedence:

    1. an explicit `opts[:shell]` wins, so nothing is added (`[]`)
    2. otherwise the instance's `configured` program is used, argv-wrapped
    3. otherwise nothing is added and Docker falls back to `/bin/sh`

  ## Examples

      [shell: ["claude"]] = Dockd.resolve_shell_arg([], "claude")
      [] = Dockd.resolve_shell_arg([shell: ["bash", "-l"]], "claude")
      [] = Dockd.resolve_shell_arg([], nil)
  """
  @spec resolve_shell_arg(keyword(), binary() | nil) :: keyword()
  def resolve_shell_arg(opts, configured) do
    cond do
      Keyword.has_key?(opts, :shell) -> []
      is_binary(configured) -> [shell: [configured]]
      true -> []
    end
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
  """
  @spec shell_send(Docker.Terminal.handle(), iodata(), keyword()) ::
          {:ok, {binary() | {binary(), binary()}, Docker.Terminal.handle()}}
          | {:error, {term(), Docker.Terminal.handle()}}
  def shell_send(shell, command, opts \\ []) do
    Docker.Terminal.command(shell, command, opts)
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

  `copies` is a list of `%{src:, dest:}` maps — the same shape accepted
  by `Dockd.Spec`'s `:copy` field. Uses the same tar + put_archive
  pipeline that `apply/2` uses at create time.

  ## Examples

      :ok =
        Dockd.copy_to(instance, [
          %{src: "./config/app.env", dest: "/etc/app/app.env"},
          %{src: "./scripts", dest: "/opt/scripts"}
        ])
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
  Lists the staging directories dockd has left under
  `<system_tmp>/dockd/` on the local node.

  These are created during file copies and git repo fetches when
  preparing data for upload into a container. They are usually cleaned
  up automatically; this function exposes whatever is left.

  Reports only the local node's staging directory.
  """
  @spec list_temp_files(keyword()) :: {:ok, [Path.t()]}
  def list_temp_files(_opts \\ []) do
    {:ok, FileCopy.list_temp_files()}
  end

  @doc """
  Deletes every staging directory dockd has left under
  `<system_tmp>/dockd/` on the local node.
  """
  @spec delete_temp_files(keyword()) :: :ok
  def delete_temp_files(_opts \\ []) do
    FileCopy.delete_temp_files()
  end

  @doc """
  Returns an aggregate info map about dockd's state on the local node.

  The shape is `%{temp_files: %{...}}` and is intentionally
  extension-friendly: callers should pattern-match on the keys they
  care about so future additions don't conflict with existing data.

  Currently included:

    - `:temp_files` — `%{count, total_bytes, oldest_at, newest_at}` for
      the staging dir under `<system_tmp>/dockd/`.
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

  # ---------------------------------------------------------------------------

  # Reads the instance's configured program. Avoids I/O when we already hold the
  # hydrated struct; auto-hydrates a bare ref via get/2 (threading Docker opts).
  defp configured_shell(%Instance{shell: shell}, _opts), do: shell

  defp configured_shell(ref, opts) when is_binary(ref) do
    case get(ref, opts) do
      {:ok, %Instance{shell: shell}} -> shell
      _ -> nil
    end
  end

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

  defp check_spec_instance_name(spec_opts) do
    case Keyword.get(spec_opts, :instance_name) do
      name when is_binary(name) and name !== "" ->
        :ok

      _ ->
        {:error,
         %Error{phase: :validate, message: "Dockd.apply/2 requires a non-empty :instance_name option"}}
    end
  end

  defp check_attrs_instance_name(attrs) do
    case Map.get(attrs, :instance_name) do
      name when is_binary(name) and name !== "" ->
        :ok

      _ ->
        {:error,
         %Error{
           phase: :validate,
           message: ~s(package is missing a non-empty "instance_name" field)
         }}
    end
  end

  defp load_package_spec(path) do
    with {:ok, decoded} <- Parser.parse_file(path),
         {:ok, substituted} <- Interpolator.substitute(decoded, System.get_env()),
         {:ok, attrs} <- Normalizer.normalize(substituted, Path.dirname(path)),
         :ok <- check_attrs_instance_name(attrs) do
      {:ok, Spec.from_attrs(attrs)}
    end
  end
end
