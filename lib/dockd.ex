defmodule Dockd do
  @moduledoc """
  Public API for dockd.

  Dockd manages local Docker containers as named instances ("instances"). The
  API is intentionally stateless: there is no in-process registry, no GenServer,
  no local store, and nothing derived is cached anywhere. Every container that
  dockd creates carries the marker label `org.dockd.instance=true` plus its
  instance name as `org.dockd.instance.name`, so a fresh BEAM can rediscover the
  full set of managed instances by querying Docker alone.

  ## Every required input is an argument

  Dockd reads no environment variable, no application config, no home directory,
  no current working directory, and no system temp directory. There is nothing to
  configure, because there is no configuration: anything a function needs, it
  takes as an argument.

  Four runtime inputs recur across the API and none of them has a default:

    - `endpoint` — the Docker daemon, e.g. `"unix:///var/run/docker.sock"` or
      `"tcp://10.0.0.1:2376"`. Without it the underlying client would fall back to
      `DOCKER_HOST`, which would make *which daemon your containers land on*
      depend on ambient process state.
    - `disk_mount_enabled` — whether host mounts, repo clones, file copies, and
      host-derived env are permitted. It fails **closed**: there is no clause that
      reads an absent value as permission to expose the host.
    - `host_env` — the map that `:env` entries and `${VAR}` interpolation resolve
      against. Pass `%{}` and a package can reach nothing from the host; pass the
      specific names it should see, and nothing more.
    - `temp_root` — the host directory used to stage repo clones and file copies.

  Host tooling (`:git_path`, `:git_env`, `:tar_path`, `:tar_env`) stays in `opts`
  because only some specs need it — but a spec that clones a repo or copies a file
  without it is a `:validate` error, never a `PATH` lookup.

  ## Getting Started

  With a Docker daemon running locally, apply an installed package by name and
  you have a live instance:

      > endpoint = "unix:///var/run/docker.sock"
      > {:ok, %Dockd.ApplyResult{instance: instance}} =
      ...>   Dockd.apply_package(root, "webapp", endpoint, false, %{}, System.tmp_dir!())

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

      > :ok = Dockd.destroy(instance, endpoint)

  For a shell a *human* drives, in a real terminal window with its own TTY, see
  `Dockd.Shell` instead — `open_shell/3` is the programmatic form.

  `apply_package/7` resolves package names against the `root` you pass and runs
  the full provisioning pipeline (pull or build, create, start, fetch repos,
  copy files, run setup steps). The returned `Dockd.Instance` is a
  view of the live container — pass it (or its name) to any other
  function in this module. See "Packages" below for the full
  resolution rules and how to install additional package sets from
  git.

  ## Lifecycle

    - `apply/6` — create a container from a `Dockd.Spec`. Returns a
      `Dockd.ApplyResult` carrying the resulting `Dockd.Instance` and any
      step results from provisioning.
    - `apply_image/7` — the same, building the spec from an image and an
      instance name.
    - `apply_package/7` — the same, loading the spec from a JSON package file
      (see "Packages" below). `load_package_spec/3` is the read half on its own.
    - `list/2` — enumerate every dockd-managed `Instance` currently on the
      daemon.
    - `get/3` — fetch one `Instance` by its instance name.
    - `start/3` / `stop/3` / `restart/3` — control the container without
      destroying it.
    - `destroy/3` — stop and remove an instance.

  ## Packages on disk

    - `install_packages/3` — install a package set from a git repository or a
      local directory.
    - `new_package/3` — scaffold a new package's files on disk.
    - `list_packages/2` — enumerate installed packages.
    - `delete_package/3` — remove an installed package from a packages root.

  ## Packages

  A package is a directory under a packages `root` containing a
  `package.json` (the serialized `Dockd.Spec`: image, shell, env,
  mounts, repos, copies, setup steps, etc.) plus any supporting files
  the spec references — typically a `Dockerfile` for `build`-based
  packages. The directory name is the package's identity.

  `apply_package/7` resolves its reference as follows:

    - any string ending in `.json` is treated as a literal file path
    - any other string containing `/` is treated as a package directory
      and resolves to `<dir>/package.json`
    - any other string is resolved against `<root>/<name>/package.json`

  `root` is an argument. There is no configured packages root and no
  `DOCKD_PACKAGES_PATH`: `~/.dockd/packages` is a fine choice, but it is the
  caller's choice to make and to write down.

  Packages generated or installed into a root can be applied by basename:

      root = Path.join(System.user_home!(), ".dockd/packages")

      # Resolves to <root>/webapp/package.json
      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply_package(root, "webapp", endpoint, false, %{}, System.tmp_dir!())

      # Explicit directory, or explicit file path. `root` is unused for these,
      # but still passed so the argument list keeps one shape.
      {:ok, result} =
        Dockd.apply_package(root, "./my-stack", endpoint, false, %{}, tmp)

      {:ok, result} =
        Dockd.apply_package(root, "./my-stack/package.json", endpoint, false, %{}, tmp)

  Additional packages are installed with `install_packages/3`, from either a
  git repository or a local directory. Every `<source>/packages/<name>/`
  directory that contains a `package.json` is copied into `<root>/<name>/`, after
  which the package can be applied by name. `list_packages/2` enumerates what is
  currently installed, and `delete_package/3` removes a package by name.

      {:ok, ["webapp"]} = Dockd.install_packages(root, "./my-recipes")

      [%{name: "webapp"}] = Dockd.list_packages(root)

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

  Dockd writes copied files and cloned repos to a staging dir under the
  `temp_root` you pass before uploading them into containers. These functions
  report and clean up that staging dir, and each takes the root as its argument:

    - `list_temp_files/1`
    - `delete_temp_files/1` — deletes recursively, so it refuses `""`, a relative
      path, and `"/"`. The directory a destructive sweep targets has to be one
      the caller named.

  ## Options

  Beyond the required positional arguments, public functions take a trailing
  `opts` keyword list for genuinely optional caller context: `:api_version`,
  `:platform`, `:networks`, `:network_mode`, and the host tooling
  (`:git_path`, `:git_env`, `:tar_path`, `:tar_env`, `:tar_extra_args`,
  `:container_staging_root`). See `option_keys/0`. None of these survive on the
  container.

  Keys that used to live here and are now positional — `:socket`, `:host`,
  `:disk_mount_enabled`, `:packages_path`, `:dest_dir` — are rejected with a
  message naming their replacement, rather than silently ignored.
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

  @typedoc """
  The host environment `:env` entries and `${VAR}` interpolation resolve against.

  Always an explicit argument, never `System.get_env/0`: a package or spec can
  only reach the values the caller chose to hand it. `%{}` resolves nothing.
  """
  @type host_env :: %{optional(binary()) => binary()}

  @log_param_keys [:tail, :since, :until, :follow]
  @log_option_keys [:stdout, :stderr, :timestamps]

  @doc """
  Returns the caller-runtime option keys `apply/6` reads.

  These are genuinely optional: Docker request tuning (`:api_version`,
  `:platform`, `:networks`, `:network_mode`) and the host tooling a spec needs
  only when it clones a repo or copies a file (`:git_path`, `:git_env`,
  `:tar_path`, `:tar_env`, `:tar_extra_args`, `:container_staging_root`).

  The daemon endpoint and `disk_mount_enabled` are *not* here — they are required
  positional arguments, so they cannot be forgotten and silently defaulted.

  Keys outside this list are ignored, as in any keyword-option API.
  """
  @spec option_keys() :: [atom()]
  def option_keys do
    [
      :api_version,
      :platform,
      :networks,
      :network_mode,
      :git_path,
      :git_env,
      :tar_path,
      :tar_env,
      :tar_extra_args,
      :container_staging_root
    ]
  end

  @doc """
  Creates a Docker container from `spec` and returns the result.

  Takes a `%Dockd.Spec{}` and its four required runtime inputs:

    - `endpoint` — the Docker daemon, e.g. `"unix:///var/run/docker.sock"`
    - `disk_mount_enabled` — `true` permits host mounts, repo clones, file copies
      and host-derived env; `false` strips them
    - `host_env` — the environment `:env` entries resolve against. `%{}` resolves
      nothing from the host
    - `temp_root` — absolute host directory to stage repo clones and file copies in

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

        {:error, %Dockd.Error{instance: instance}} when not is_nil(instance) ->
          Dockd.destroy(instance, endpoint)
      end
  """
  @spec apply(Spec.t(), binary(), boolean(), host_env(), Path.t(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
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
          {:ok, ApplyResult.t()} | {:error, Error.t()}
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
  Loads a JSON package from `root` and applies it.

  Resolves the package reference as described in the "Packages" section:

    - `<name>.json` or any path containing `/` is treated as a file path
    - any other string is resolved against `<root>/<name>/package.json`

  The document is read, parsed, interpolated against `host_env`, and normalized
  into spec attributes. `host_env` is the same map `:env` entries resolve against,
  so `${VAR}` in a package expands only to values the caller supplied — pass `%{}`
  to substitute nothing.

  ## Examples

      # Resolved against <root>/elixir/package.json.
      {:ok, %Dockd.ApplyResult{instance: instance}} =
        Dockd.apply_package(root, "elixir", endpoint, false, %{}, tmp)

      # Explicit path — anything with `/` or ending in `.json`. `root` is unused
      # for these, but still required so the argument list does not change shape.
      {:ok, result} =
        Dockd.apply_package(root, "/abs/path/stack.json", endpoint, false, %{}, tmp)

      # Interpolating ${HOME} in the package requires passing it deliberately.
      {:ok, result} =
        Dockd.apply_package(root, "elixir", endpoint, true,
          %{"HOME" => System.user_home!()}, tmp)
  """
  @spec apply_package(Path.t(), binary(), binary(), boolean(), host_env(), Path.t(), keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
  def apply_package(root, ref, endpoint, disk_mount_enabled, host_env, temp_root, opts \\ []) do
    with {:ok, spec} <- load_package_spec(root, ref, host_env) do
      Provisioner.run(spec, endpoint, disk_mount_enabled, host_env, temp_root, opts)
    end
  end

  @doc """
  Loads a package from `root` into a `Dockd.Spec` without applying it.

  The read half of `apply_package/7`: resolve the reference, parse the JSON,
  substitute `${VAR}` from `host_env`, normalize, and validate. Useful for
  inspecting or adjusting a spec before handing it to `apply/6`, and the
  lower-arity path when the four runtime inputs are not all in hand yet.
  """
  @spec load_package_spec(Path.t(), binary(), host_env()) ::
          {:ok, Spec.t()} | {:error, Error.t()}
  def load_package_spec(root, ref, host_env) do
    path = Packages.resolve_path(root, ref)

    with {:ok, decoded} <- Parser.parse_file(path),
         {:ok, substituted} <- Interpolator.substitute(decoded, host_env),
         {:ok, attrs} <- Normalizer.normalize(substituted, Path.dirname(path)) do
      case Spec.from_attrs(attrs) do
        {:ok, spec} -> {:ok, spec}
        {:error, error} -> {:error, prefix_message(error, path)}
      end
    end
  end

  @doc """
  Installs packages from a git repository or a local directory into the
  configured packages root.

  `ref` selects the source: an existing directory on the host installs from
  that directory, anything else is treated as a git URL and cloned with the
  host `git` binary. Either way, every `<source>/packages/<name>/` directory
  containing a `package.json` is copied into `<root>/<name>/`, and an
  existing target directory is replaced.

  A git URL can be anything `git clone` accepts (HTTPS, SSH, or the
  `github.com/user/repo` shorthand). A source with no top-level `packages/`
  directory is a `:fetch` error.

  Options:

    - `:ref` — git branch or tag to clone. Ignored when installing from a
      local directory, which is used exactly as it is on disk.
    - `:packages_subdir` — the subdirectory of the source to read packages from.
      Defaults to `"packages"`.

  A git install additionally requires `:staging_root`, `:git_path`, and `:git_env`
  — the clone directory, the `git` executable, and the exact environment to run it
  in. They are options rather than positional arguments because a local-directory
  install has no use for them, but a git install without them is a `:fetch` error,
  never a PATH lookup.

  Returns `{:ok, [name]}` with the installed package names.

  ## Examples

      # From a local checkout — anything that is an existing directory.
      {:ok, ["foo", "bar"]} = Dockd.install_packages(root, "./my-recipes")

      # From a remote repository.
      {:ok, ["foo", "bar"]} =
        Dockd.install_packages(root, "https://github.com/me/recipes",
          staging_root: System.tmp_dir!(),
          git_path: "/usr/bin/git",
          git_env: %{"HOME" => System.user_home!()},
          ref: "v1.2.0"
        )
  """
  @spec install_packages(Path.t(), binary(), keyword()) ::
          {:ok, [binary()]} | {:error, Error.t()}
  def install_packages(root, ref, opts \\ []) do
    if File.dir?(ref) do
      Packages.install_from_path(root, ref, opts)
    else
      Packages.install_from_git(
        root,
        ref,
        Keyword.get(opts, :staging_root),
        Keyword.get(opts, :git_path),
        Keyword.get(opts, :git_env),
        opts
      )
    end
  end

  @doc """
  Scaffolds a new package into `dir`, so you never have to hand-write
  `package.json` and `Dockerfile`.

  `dir` **is** the package directory, and `instance_name` is the container name
  the package will create. The generated package always builds its own image from
  the generated `Dockerfile`, so `:image` is the tag that build produces and
  `:from` is the Dockerfile's base image.

  Only the keys you pass are written. Refuses to touch an existing directory
  unless `force: true`, and validates before writing anything — a rejected call
  leaves nothing behind. See `Dockd.Packages.new/3` for the full option list.

  ## Examples

      # Minimal — image defaults to dockd-greeter:latest, Dockerfile to
      # FROM Dockd.Spec.Encoder.default_from/0.
      {:ok, %{files: _}} = Dockd.new_package("./greeter", "greeter")

      # Into a shareable package set, ready for install_packages/3.
      {:ok, %{instance_name: "greeter"}} =
        Dockd.new_package("./my-recipes/packages/greeter", "greeter",
          image: "dockd-greeter:1",
          from: "busybox:1.37.0",
          shell: "/bin/sh",
          env: [{"API_KEY", optional: true}],
          steps: [%{step_name: "verify", cmd: ["sh", "-c", "test -f /etc/greeting"]}]
        )

      {:ok, ["greeter"]} = Dockd.install_packages(root, "./my-recipes")
  """
  @spec new_package(Path.t(), binary(), keyword()) ::
          {:ok,
           %{
             instance_name: binary(),
             path: Path.t(),
             files: [Path.t()],
             overwrote?: boolean()
           }}
          | {:error, Error.t()}
  def new_package(dir, instance_name, opts \\ []) do
    Packages.new(dir, instance_name, opts)
  end

  @doc """
  Lists every package installed under `root`.

  A subdirectory counts as an installed package when it contains a readable
  `package.json`. Each entry is a map with `:name`, `:path`, and `:spec`,
  sorted by name.

  `:spec` is itself a result tuple — `{:ok, %Dockd.Spec{}}` or
  `{:error, %Dockd.Error{}}` — so one malformed `package.json` surfaces its own
  parse error instead of hiding every other installed package.

  Never fails: an unreadable or missing `root` returns `[]`.

  Note that specs are parsed without `${VAR}` interpolation, so this is safe to
  call for metadata (image, shell, description) even for a package that
  references variables you have no values for.

  ## Examples

      [%{name: "webapp", path: path, spec: {:ok, spec}}] = Dockd.list_packages(root)

      [] = Dockd.list_packages("/tmp/empty")
  """
  @spec list_packages(Path.t(), keyword()) :: [
          %{
            name: binary(),
            path: Path.t(),
            spec: {:ok, Spec.t()} | {:error, Error.t()}
          }
        ]
  def list_packages(root, opts \\ []) do
    Packages.list(root, opts)
  end

  @doc """
  Deletes an installed package from `root`.

  Takes a bare package name — the same name `apply_package/7` resolves and
  `list_packages/2` reports. Paths and `.json` references are rejected with a
  `:validate` error, so nothing outside `root` can be removed.

  Idempotent — deleting a package that is not installed returns `:ok`. Running
  instances created from the package are not touched; a package is only the
  recipe on disk.

  ## Examples

      {:ok, ["webapp"]} = Dockd.install_packages(root, "./my-recipes")
      :ok = Dockd.delete_package(root, "webapp")

      # Already gone — still :ok.
      :ok = Dockd.delete_package(root, "webapp")
  """
  @spec delete_package(Path.t(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def delete_package(root, name, opts \\ []) do
    Packages.delete(root, name, opts)
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
  @spec list(binary(), keyword()) :: {:ok, [Instance.t()]} | {:error, Error.t()}
  def list(endpoint, opts \\ []) do
    with {:ok, docker_options} <- Provisioner.docker_options_from(endpoint, opts) do
      marker = "#{Instance.marker_label()}=true"

      case Docker.list_containers(%{all: true}, [labels: [marker]] ++ docker_options) do
        {:ok, summaries} ->
          hydrate_each(summaries, docker_options, [])

        {:error, reason} ->
          {:error,
           Error.docker_phase_error(:discover, "failed to list Docker containers", reason, nil)}
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
        {:error, %Dockd.Error{} = err} -> err
      end
  """
  @spec get(binary(), binary(), keyword()) :: {:ok, Instance.t()} | {:error, Error.t()}
  def get(name, endpoint, opts \\ []) do
    with {:ok, docker_options} <- Provisioner.docker_options_from(endpoint, opts) do
      case Docker.find_container(Spec.prefix_name(name), docker_options) do
        {:ok, body} ->
          {:ok, Instance.from_inspect(body)}

        {:error, reason} ->
          {:error,
           Error.docker_phase_error(:discover, "failed to inspect Docker container", reason, nil)}
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
  @spec destroy(Instance.t() | binary(), binary(), keyword()) :: :ok | {:error, Error.t()}
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
  @spec start(Instance.t() | binary(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def start(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, docker_options}} <- resolve_ref(instance_or_ref, endpoint, opts) do
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
  end

  @doc """
  Stops a running instance without removing it.

  Idempotent — stopping an already-stopped instance returns `:ok`.

  ## Examples

      :ok = Dockd.stop(instance, endpoint)
      :ok = Dockd.stop("smoke", endpoint)
  """
  @spec stop(Instance.t() | binary(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def stop(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, docker_options}} <- resolve_ref(instance_or_ref, endpoint, opts) do
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
  end

  @doc """
  Stops then starts an instance.

  Equivalent to `stop/3` followed by `start/3`. If the stop step fails
  the start step is skipped and the stop error is returned.

  ## Examples

      :ok = Dockd.restart(instance, endpoint)
  """
  @spec restart(Instance.t() | binary(), binary(), keyword()) :: :ok | {:error, Error.t()}
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
          {:ok, boolean()} | {:error, Error.t()}
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
          Docker.result(binary()) | {:error, Error.t()}
  def logs(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, docker_options}} <- resolve_ref(instance_or_ref, endpoint, opts) do
      {params, log_options} = split_log_opts(opts)
      Docker.container_logs(ref, params, log_options ++ docker_options)
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
          {:ok, map()} | {:error, Error.t()}
  def inspect(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, docker_options}} <- resolve_ref(instance_or_ref, endpoint, opts) do
      case Docker.find_container(ref, docker_options) do
        {:ok, body} ->
          {:ok, body}

        {:error, reason} ->
          {:error,
           Error.docker_phase_error(:discover, "failed to inspect Docker container", reason, nil)}
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
          {:ok, Instance.t()} | {:error, Error.t()}
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
          Docker.result(Docker.exec_result()) | {:error, Error.t()}
  def shell_command(instance_or_ref, command, endpoint, opts \\ []) do
    with {:ok, {ref, instance_opts}} <- resolve_ref(instance_or_ref, endpoint, opts) do
      Docker.Terminal.run_with_status(ref, command, instance_opts)
    end
  end

  @doc """
  Opens a persistent interactive shell on the instance.

  Returns a `Docker.Terminal.handle/0` (the container ref) that
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
          Docker.result(Docker.Terminal.handle()) | {:error, Error.t()}
  def open_shell(instance_or_ref, endpoint, opts \\ []) do
    with {:ok, {ref, instance_opts}} <- resolve_ref(instance_or_ref, endpoint, opts),
         {:ok, configured} <- configured_shell_for(instance_or_ref, endpoint, opts) do
      open_opts = instance_opts ++ resolve_shell_arg(opts, configured)

      with {:ok, _session} <- Docker.Terminal.open(ref, open_opts) do
        {:ok, ref}
      end
    end
  end

  @doc """
  Decides the `:shell` option to add when opening a shell into an instance.

  Exposed because `open_shell/3`'s shell precedence is worth being able to
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

  `copies` is a list of `%{src:, dest:}` maps — the same shape accepted by
  `Dockd.Spec`'s `:copy` field, with `src` required to be an absolute path. Uses
  the same tar + put_archive pipeline that `apply/6` uses at create time, so it
  needs the same `temp_root` to stage in and the same `:tar_path` / `:tar_env`.

  ## Examples

      :ok =
        Dockd.copy_to(
          instance,
          [
            %{src: "/srv/config/app.env", dest: "/etc/app/app.env"},
            %{src: "/srv/scripts", dest: "/opt/scripts"}
          ],
          System.tmp_dir!(),
          endpoint,
          tar_path: "/usr/bin/tar",
          tar_env: %{}
        )
  """
  @spec copy_to(Instance.t() | binary(), [map()], Path.t(), binary(), keyword()) ::
          :ok | {:error, Error.t()}
  def copy_to(instance_or_ref, copies, temp_root, endpoint, opts \\ []) do
    with {:ok, container_id, docker_options} <-
           resolve_container_id(instance_or_ref, endpoint, opts) do
      FileCopy.copy_files(
        copies,
        container_id,
        temp_root,
        Keyword.get(opts, :tar_path),
        Keyword.get(opts, :tar_env),
        docker_options,
        opts
      )
    end
  end

  @doc """
  Lists the staging directories dockd has left under `temp_root` on the local
  node.

  These are created during file copies and git repo fetches when preparing data
  for upload into a container. They are usually cleaned up automatically; this
  function exposes whatever is left.

  `temp_root` is the same directory you passed to `apply/6` or `copy_to/5`.
  """
  @spec list_temp_files(Path.t()) :: {:ok, [Path.t()]}
  def list_temp_files(temp_root) do
    {:ok, FileCopy.list_temp_files(temp_root)}
  end

  @doc """
  Deletes every staging directory dockd has left under `temp_root` on the local
  node, leaving `temp_root` itself in place.

  This deletes recursively, so `temp_root` is a required argument rather than a
  value read from the environment: the directory a destructive sweep targets must
  be one the caller named. `""`, a relative path, and `"/"` are refused.
  """
  @spec delete_temp_files(Path.t()) :: :ok | {:error, Error.t()}
  def delete_temp_files(temp_root) do
    FileCopy.delete_temp_files(temp_root)
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
    id = Map.fetch!(summary, "Id")

    case Docker.find_container(id, docker_options) do
      {:ok, body} ->
        hydrate_each(rest, docker_options, [Instance.from_inspect(body) | acc])

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:discover, "failed to inspect Docker container", reason, nil)}
    end
  end

  defp prefix_message(%Error{message: message} = error, path),
    do: %{error | message: "#{path}: #{message}"}
end
