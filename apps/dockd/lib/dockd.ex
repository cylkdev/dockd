defmodule Dockd do
  @moduledoc """
  Public API for dockd.

  Dockd manages local Docker containers as named instances ("instances"). The
  API is intentionally stateless: there is no in-process registry, no GenServer,
  no local store. Every container that dockd creates carries the marker label
  `org.dockd.instance=true` plus its instance name as
  `org.dockd.instance.name`, so a fresh BEAM can rediscover the full set of
  managed instances by querying Docker alone.

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
  it with `close_shell/1` when done.

      > {:ok, shell} = Dockd.open_shell(instance)
      > {:ok, {_, shell}} = Dockd.shell_send(shell, "cd /tmp")
      > {:ok, {"/tmp\\n", shell}} = Dockd.shell_send(shell, "pwd")
      > {:ok, {_, shell}} = Dockd.shell_send(shell, "export FOO=bar")
      > {:ok, {"bar\\n", shell}} = Dockd.shell_send(shell, "echo $FOO")
      > :ok = Dockd.close_shell(shell)

      > :ok = Dockd.destroy(instance)

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

  ## Packages

  A package is a directory under the configured packages root containing a
  `package.json` (the serialized `Dockd.Spec`: image, shell, env,
  mounts, repos, copies, setup steps, etc.) plus any supporting files
  the spec references — typically a `Dockerfile` for `build`-based
  packages. The directory name is the package's identity.

  `apply_package/2` resolves its reference the same way the `mix dockd`
  CLI does:

    - any string ending in `.json` is treated as a literal file path
    - any other string containing `/` is treated as a package directory
      and resolves to `<dir>/package.json`
    - any other string is resolved against
      `<packages_root>/<name>/package.json`

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

  Additional packages can be fetched from a git repository with
  `install_packages/2` (or `mix dockd.package.install --source git --git-url=<url>`).
  Every `<repo>/packages/<name>/` directory that contains a `package.json` is
  copied into `<packages_root>/<name>/`, after which the package can be applied
  by name.

  ## Visibility

    - `running?/2` — boolean liveness check.
    - `logs/2` — fetch container stdout/stderr as a binary.
    - `inspect/2` — return the raw Docker inspect map (escape hatch for
      ports, networks, exit code, started_at, etc.).
    - `refresh/2` — re-fetch a fresh `Instance` from Docker after a state
      change.

  ## Operating on instances

    - `shell_command/3` — one-shot exec, captures stdout/stderr and exit
      code.
    - `open_shell/2` / `shell_send/3` / `close_shell/1` — persistent
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

  All implementation lives in `Dockd.Core`; the functions in this module
  are thin forwarders.
  """

  alias Dockd.ApplyResult
  alias Dockd.Core
  alias Dockd.Error
  alias Dockd.Instance
  alias Dockd.Spec

  @doc """
  Creates a Docker container from `spec_or_image` and returns the result.

  Three input shapes are accepted:

    - a `%Dockd.Spec{}` — used as-is
    - an image string plus a keyword list of spec options (the Elixir-native
      shape; equivalent to calling `Dockd.Spec.from_opts/2` first)
    - an image string alone — equivalent to `Spec.from_opts(image, [])`

  Per-call options (Docker connection settings and `:disk_mount_enabled`)
  and spec options share the same flat keyword list as the second
  argument. `Dockd.Spec.option_keys/0` decides the split: any key it
  claims is routed into `Spec.from_opts/2`, anything else is treated as
  a per-call option. Unknown keys are rejected.

  ## Examples

      # Image string alone — generates a container name automatically.
      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply("busybox:1.37.0")

      # Image plus spec options.
      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply("busybox:1.37.0",
          name: "smoke",
          shell: "/bin/sh",
          env: ["FOO=bar"],
          steps: [%{run: "mkdir -p /work"}]
        )

      # Spec options and per-call options share one flat keyword list.
      {:ok, result} =
        Dockd.apply("busybox:1.37.0",
          name: "smoke",
          shell: "/bin/sh",
          socket: "/var/run/docker.sock"
        )

      # A pre-built %Dockd.Spec{} struct — opts is the per-call options list.
      spec = Dockd.Spec.from_opts("busybox:1.37.0", name: "smoke", shell: "/bin/sh")
      {:ok, result} = Dockd.apply(spec, socket: "/var/run/docker.sock")

      # Failure path: the error may carry the partially-created instance so
      # the caller can clean up.
      case Dockd.apply("busybox:1.37.0", steps: [%{run: "exit 1"}]) do
        {:ok, %Dockd.ApplyResult{instance: instance}} ->
          instance

        {:error, %Dockd.Error{instance: instance}} when not is_nil(instance) ->
          Dockd.destroy(instance)
      end
  """
  @spec apply(Spec.t() | binary(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
  def apply(spec_or_image, opts \\ []) do
    Core.apply(spec_or_image, opts)
  end

  @doc """
  Loads a JSON package file and applies it.

  Resolves the package reference the same way `Mix.Tasks.Dockd` does:

    - `<name>.json` or any path containing `/` is treated as a file path
    - any other string is resolved against `<packages_root>/<name>/package.json`

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
  def apply_package(ref, opts \\ []) do
    Core.apply_package(ref, opts)
  end

  @doc """
  Installs packages from a remote git repository into the local
  configured packages root.

  Clones the repo with the host `git` binary and copies every
  `<repo>/packages/<name>/` directory containing a `package.json` into
  `<packages_root>/<name>/`. An existing target directory is replaced.

  The URL can be anything `git clone` accepts (HTTPS, SSH, or the
  `github.com/user/repo` shorthand).

  Options:

    - `:ref` — git branch or tag to clone (defaults to the remote's
      default branch).

  Returns `{:ok, [name]}` with the installed package names.

  ## Examples

      {:ok, ["foo", "bar"]} =
        Dockd.install_packages("https://github.com/me/recipes")

      {:ok, _} =
        Dockd.install_packages("github.com/me/recipes", ref: "v1.2.0")
  """
  @spec install_packages(binary(), keyword()) ::
          {:ok, [binary()]} | {:error, Error.t()}
  def install_packages(url, opts \\ []) do
    Dockd.Packages.install_from_git(url, opts)
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
  def list(opts \\ []) do
    Core.list(opts)
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
  def get(name, opts \\ []) do
    Core.get(name, opts)
  end

  @doc """
  Stops and removes an instance.

  Accepts either an `Instance` struct, a Docker container ID, or a
  instance name (short or prefixed). Already-stopped and already-removed
  containers are treated as success.

  ## Examples

      # By instance struct (typical when you've just created it).
      {:ok, %Dockd.ApplyResult{instance: instance}} = Dockd.apply("busybox:1.37.0")
      :ok = Dockd.destroy(instance)

      # By short name.
      :ok = Dockd.destroy("smoke")

      # By full container name.
      :ok = Dockd.destroy("dockd-smoke")

      # By container ID.
      :ok = Dockd.destroy("a1b2c3d4e5f6")

      # Idempotent — destroying something that's already gone is :ok.
      :ok = Dockd.destroy("smoke")
      :ok = Dockd.destroy("smoke")
  """
  @spec destroy(Instance.t() | binary(), keyword()) :: :ok | {:error, Error.t()}
  def destroy(instance_or_ref, opts \\ []) do
    Core.destroy(instance_or_ref, opts)
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
    Core.start(instance_or_ref, opts)
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
    Core.stop(instance_or_ref, opts)
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
    Core.restart(instance_or_ref, opts)
  end

  @doc """
  Returns `true` when the instance's container is running on the daemon.

  Cheap — a single Docker inspect, no exec.

  ## Examples

      {:ok, true} = Dockd.running?(instance)
      {:ok, false} = Dockd.running?("smoke")
  """
  @spec running?(Instance.t() | binary(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def running?(instance_or_ref, opts \\ []) do
    {:ok, Core.running?(instance_or_ref, opts)}
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
    Core.logs(instance_or_ref, opts)
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
  @spec inspect(Instance.t() | binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(instance_or_ref, opts \\ []) do
    Core.inspect(instance_or_ref, opts)
  end

  @doc """
  Re-fetches an instance from Docker, returning a fresh `%Dockd.Instance{}`.

  Useful after `start/2`, `stop/2`, or `restart/2` to refresh the
  `:running?` field (and anything else hydrated from Docker inspect).

  ## Examples

      {:ok, fresh} = Dockd.refresh(instance)
      {:ok, fresh} = Dockd.refresh("smoke")
  """
  @spec refresh(Instance.t() | binary(), keyword()) :: {:ok, Instance.t()} | {:error, term()}
  def refresh(instance_or_ref, opts \\ []) do
    Core.refresh(instance_or_ref, opts)
  end

  @doc """
  Runs `command` inside the instance and returns the combined output plus
  exit code. `command` may be a string (run with the instance's shell) or
  an argv list (run verbatim).

  ## Examples

      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply("busybox:1.37.0", shell: "/bin/sh")

      # String form — invoked through the instance's configured shell.
      {:ok, %{stdout: "hello\\n", exit_code: 0}} =
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
    Core.shell_command(instance_or_ref, command, opts)
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
    Core.open_shell(instance_or_ref, opts)
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
    Core.shell_send(shell, command, opts)
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
    Core.close_shell(shell)
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
  def copy_to(instance_or_ref, copies, opts \\ []) when is_list(copies) do
    Core.copy_to(instance_or_ref, copies, opts)
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
  def list_temp_files(opts \\ []) do
    Core.list_temp_files(opts)
  end

  @doc """
  Deletes every staging directory dockd has left under
  `<system_tmp>/dockd/` on the targeted node.

  Deletes only the local node's staging directory.
  """
  @spec delete_temp_files(keyword()) :: :ok
  def delete_temp_files(opts \\ []) do
    Core.delete_temp_files(opts)
  end

  @doc """
  Returns an aggregate info map about dockd's state on the targeted node.

  The shape is `%{temp_files: %{...}}` and is intentionally
  extension-friendly: callers should pattern-match on the keys they
  care about so future additions don't conflict with existing data.

  Currently included:

    - `:temp_files` — `%{count, total_bytes, oldest_at, newest_at}` for
      the staging dir under `<system_tmp>/dockd/`.

  Reports only local core state.
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
  def info(opts \\ []) do
    Core.info(opts)
  end
end
