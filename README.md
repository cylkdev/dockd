# Dockd

Dockd is an Elixir library for managing local Docker containers as named,
throwaway Linux workspaces ("instances"). You describe the environment you want
-- image, files, setup commands -- and dockd builds it, runs it, and tears it
down on request.

It holds no state of its own: every container it creates is labelled, so Docker
itself is the source of truth. A fresh BEAM rediscovers every managed instance
by asking the daemon.

## Prerequisites

- [Elixir](https://elixir-lang.org/install.html) 1.17 or later
- [Docker](https://docs.docker.com/get-docker/) installed and running

Verify Docker is running:

```sh
docker info
```

If you see connection errors, start Docker Desktop (Mac/Windows) or the Docker daemon (Linux).

## Quick Start

```elixir
endpoint = "unix:///var/run/docker.sock"

# Create and start a container. The image and instance name are positional, and
# so are the four runtime inputs: endpoint, disk_mount_enabled, host_env, temp_root.
{:ok, %Dockd.ApplyResult{instance: instance}} =
  Dockd.apply_image("debian:trixie", "scratch", endpoint, false, %{}, System.tmp_dir!(),
    shell: "/bin/bash"
  )

# Run something in it.
{:ok, %{output: output, exit_code: 0}} =
  Dockd.shell_command(instance, "uname -a", endpoint)

IO.puts(output)

# Tear it down.
:ok = Dockd.destroy(instance, endpoint)
```

Any Docker image works -- `ubuntu:24.04`, `alpine:latest`, `node:20-slim`, and so on.

### Nothing is read from the environment

Dockd has no configuration. It reads no environment variable, no application
config, no home directory, no working directory, and no system temp directory —
so anything it needs, you pass. The four arguments above are the ones you will
see everywhere:

| Argument | What it decides | Pass `%{}` / `false` to... |
|----------|-----------------|----------------------------|
| `endpoint` | Which daemon your containers land on. Not `DOCKER_HOST` | — |
| `disk_mount_enabled` | Whether host mounts, file copies and host env are allowed. **No default** | `false`: allow none of it |
| `host_env` | The only values `:env` entries can resolve to | `%{}`: resolve nothing from the host |
| `temp_root` | Where file copies are staged on the host | — |

If you want the conventional locations, name them yourself — that way the choice
is visible in your code:

```elixir
endpoint  = "unix:///var/run/docker.sock"
temp_root = System.tmp_dir!()
host_env  = %{"HOME" => System.user_home!()}
```

## Elixir API

```elixir
# Create a container, running setup steps before it's considered ready.
{:ok, %Dockd.ApplyResult{instance: instance, step_results: steps}} =
  Dockd.apply_image("debian:trixie", "builder", endpoint, false, %{}, temp_root,
    shell: "/bin/bash",
    steps: [
      %{step_name: "update", cmd: ["apt-get", "update"]},
      %{step_name: "install curl", cmd: ["apt-get", "install", "-y", "curl"]}
    ]
  )

# Run a one-off command inside the instance.
# :output is stdout and stderr combined.
{:ok, %{output: "hello\n", exit_code: 0}} =
  Dockd.shell_command(instance, "echo hello", endpoint)

# Or open a persistent shell that preserves state between commands.
{:ok, shell} = Dockd.open_shell(instance, endpoint)
{:ok, {_, shell}}   = Dockd.shell_send(shell, "cd /tmp")
{:ok, {out, shell}} = Dockd.shell_send(shell, "pwd")  # out =~ "/tmp"
:ok = Dockd.close_shell(shell)

# Clean up when done.
:ok = Dockd.destroy(instance, endpoint)
```

`Dockd.apply_image/7` returns a `%Dockd.ApplyResult{}` carrying the live
`%Dockd.Instance{}` plus the captured output of each setup step. Pass the
instance (or just its name) to every other function.

Both `shell_command/4` and `open_shell/3` are thin wrappers over
[`Docker.Terminal`](https://hexdocs.pm/docker/Docker.Terminal.html): use
`shell_command/4` for stateless one-shot commands (output + exit code),
and `open_shell` + `shell_send` + `close_shell` when commands must build
on each other (working directory, shell variables, etc.).

### The whole API

| | |
|---|---|
| Create | `apply/6`, `apply_image/7` |
| Find | `list/2`, `get/3`, `refresh/3` |
| Control | `start/3`, `stop/3`, `restart/3`, `destroy/3` |
| Inspect | `running?/3`, `logs/3`, `inspect/3` |
| Operate | `shell_command/4`, `open_shell/3`, `shell_send/3`, `close_shell/2`, `copy_to/5` |
| Staging | `list_temp_files/1`, `delete_temp_files/1` |

Nineteen functions, and each takes the endpoint after its subject.

## Specs

A container is described by a `Dockd.Spec`. There are two ways to build one, and
both go through the same validation:

```elixir
# From an image and a name.
{:ok, spec} = Dockd.Spec.new("debian:trixie", "builder", shell: "/bin/bash")

# From a plain, atom-keyed map.
{:ok, spec} =
  Dockd.Spec.from_map(%{
    instance_name: "builder",
    image: "debian:trixie",
    shell: "/bin/bash"
  })

{:ok, result} = Dockd.apply(spec, endpoint, false, %{}, temp_root)
```

`Spec.new/3` returns `{:ok, spec}` or a `:validate` error rather than raising.

### Instance options

These describe the workspace itself. They map one-to-one onto `Dockd.Spec`
fields (`Dockd.Spec.option_keys/0`), and are the same keys a spec map accepts.

The instance name is **not** among them: it is a positional argument of
`apply_image/7` and `Spec.new/3`, because it is always required. Dockd stores the
short name you pass and derives the container name `dockd-<name>` itself, so
passing a name that already starts with `dockd-` is a `:validate` error rather
than a silent duplicate.

| Option | Default | Description |
|--------|---------|-------------|
| `:shell` | `"/bin/sh"` | Shell to use inside the container |
| `:description` | `nil` | Free-text description, stored on the spec |
| `:steps` | `[]` | Commands to run inside the container before it's ready |
| `:copy` | `[]` | Files or directories to ship from the host into the container as one-way snapshots |
| `:mounts` | `[]` | Live host↔container shares - strings (`"host:container[:ro]"`) or structured maps (`%{type:, source:, target:, ...}`) |
| `:env` | `[]` | Container env entries - see below |
| `:labels` | `%{}` | Extra container labels, merged with the labels dockd manages |
| `:build` | `nil` | Build the image locally from a `%{dockerfile:, context:, args:, ...}` map instead of pulling |

Each setup step is a map with a `:step_name` and a `:cmd` (list of strings):

```elixir
%{step_name: "install git", cmd: ["apt-get", "install", "-y", "git"]}
```

Each `:env` entry is one of exactly two shapes:

| Shape | Behavior |
|-------|----------|
| `"FOO=bar"` | literal - passed through unchanged |
| `"FOO"` (no `=`) | read from `host_env`; **`:validate` error if absent from it** |

"Read from `host_env`" means *from the map you passed* — never from the calling
process. There is no `:default` and no `:optional`, so there is no precedence
rule to remember: a name is either written down as a literal, or it comes from
the map, and a name the map does not have is an error.

### Caller options

These tune the request rather than describing the workspace. They share the same
flat keyword list and are never stored on the container.

| Option | Description |
|--------|-------------|
| `:api_version` | Docker Engine API version to talk to |
| `:platform` | Target platform (e.g. `"linux/amd64"`) |
| `:networks` / `:network_mode` | Container networking |
| `:container_staging_root` | Writable directory inside the container to stage uploads. Defaults to `"/tmp"` |

There is no host tooling to supply. File copies are tarred in-process with OTP's
`:erl_tar`, so dockd runs no external program and looks nothing up on `PATH`.

The daemon endpoint and `disk_mount_enabled` are deliberately *not* here: they
are positional, so they cannot be forgotten and silently defaulted.

## Packages

A **package** is just a map — an atom-keyed Elixir map that describes a complete
instance, so you can launch a reusable environment with one call:

```elixir
@hello %{
  instance_name: "hello",
  image: "busybox:1.37.0",
  shell: "/bin/sh"
}

{:ok, spec} = Dockd.Spec.from_map(@hello)

{:ok, %Dockd.ApplyResult{instance: instance}} =
  Dockd.apply(spec, endpoint, false, %{}, temp_root)
```

That's the whole contract. The keys are the instance options above, with
`:image` and `:instance_name` both required. **Keys are atoms**, here and in
every nested `:build`, `:steps`, `:copy` and `:mounts` entry — a string key is
rejected rather than accepted as a second spelling. Unknown keys are rejected
with a `:validate` error too, so typos are caught early.

The one place strings stay strings is payload dockd hands over verbatim: label
names, env-var names, and anything Docker sends back.

Setting `:shell` is what keeps the container alive after it starts — see
[the `shell` field](#shell) below.

### What dockd deliberately does not do

**No file I/O.** Keeping a package in a file is a fine idea — loading it is your
code, not dockd's. There is no packages root, no `DOCKD_PACKAGES_PATH`, no
name-to-path resolution, no installer, and no scaffolder.

**No `${VAR}` substitution.** You build the map, so you interpolate it. What is
in the map is what reaches Docker.

**No relative paths.** With no package directory to resolve against, a relative
`:build` `:dockerfile` or `:context` would fall back to your current working
directory — so it is a `:validate` error instead. Absolutize it yourself:

```elixir
spec_map = update_in(package, [:build, :dockerfile], &Path.expand(&1, dir))
```

One line you can read, in your code, instead of a resolution rule you have to
look up.

### Three distinct "name" fields

Three unrelated things could each be called a name, so each has its own key:
`:instance_name` at the top level names the container, `:step_name` names a
setup step, and `:name` is not a spec key at all.

### Field reference

The valid keys are `instance_name`, `description`, `image`, `shell`, `steps`,
`build`, `copy`, `env`, `mounts`, and `labels`.

#### `image` (string, required)

A Docker registry reference. With `:build` set, this is the tag the built image
will receive instead.

#### `instance_name` (string, required)

The container's name, prefixed with `dockd-`. There is no auto-generated
default. Because the name is fixed by the map, applying the same map twice
concurrently will collide.

#### `shell`

Path inside the container that an interactive exec should launch. Use the
entrypoint of whatever tool you actually want — for an SSH-style shell,
`"/bin/bash"`; for a CLI tool that runs as a single binary, point directly at it.

Setting it also runs the container with an interactive shell as its command,
which is what keeps a container alive whose image would otherwise run to
completion and exit. **Omit it and an image like `busybox` exits immediately**,
so later `shell_command/4` calls fail with a Docker 409 ("container is not
running"). Set `:shell` for any instance you intend to keep around.

#### `description`, `labels`

`description` is free text carried on the spec. `labels` is a map of extra
Docker labels, merged with the ones dockd manages for discovery.

#### `env` (list of strings)

Two shapes, as described under [Instance options](#instance-options):
`"FOO=bar"` for a literal, `"FOO"` to read from `host_env`.

```elixir
env: ["NODE_ENV=development", "GITHUB_TOKEN"]
```

#### `mounts` (list)

Live host↔container shares. Each entry is one of two shapes:

| Shape | Maps to | Use when |
|-------|---------|----------|
| `"host:container"` or `"host:container:ro"` | `HostConfig.Binds` | the simple case - sharing one directory |
| `%{type: …, source: …, target: …}` map | `HostConfig.Mounts` | tmpfs, named volumes, or bind mounts with options |

```elixir
mounts: ["/Users/me/project:/instance", %{type: "tmpfs", target: "/scratch"}]
```

#### `copy` (list of maps)

One-way snapshots from the host into the container.

| Key | Required | Description |
|-----|----------|-------------|
| `src` | yes | Absolute host path (file or directory) |
| `dest` | yes | Absolute path inside the container; missing parents are created |
| `mode` | no | Permission bits applied with `chmod -R` (e.g. `"0600"`) |
| `owner` | no | Ownership applied with `chown -R` (e.g. `"root:root"`) |

Unlike `mounts`, the container receives its own copy — writes inside the
container do **not** propagate to the host. Use `mounts` when the container
should see live host changes, and `copy` when it needs an isolated snapshot.

To get a git repository into a container, clone it on the host yourself and
`copy` the result, or clone it in a setup `step`. Dockd does not run `git`.

#### `steps` (list of maps)

Commands to run inside the container after files are in place but before the
instance is considered ready.

| Key | Required | Description |
|-----|----------|-------------|
| `step_name` | yes | Human-readable name shown in errors and `step_results` |
| `cmd` | yes | Argv list (e.g. `["npm", "install"]`) - never a single string |
| `env` | no | Per-step env entries, on top of the container's env |
| `workdir` | no | Working directory for this step |
| `user` | no | User to run the step as |

A step exiting non-zero halts with a `:setup` error carrying the captured output
and exit code. Earlier steps' results are preserved on the error.

#### `build` (map)

Build the image locally from a Dockerfile instead of pulling. Setting `:build`
triggers the build path; absence triggers the pull path.

| Key | Required | Description |
|-----|----------|-------------|
| `dockerfile` | yes | **Absolute** path to a Dockerfile, or to a directory containing one |
| `context` | no | **Absolute** build context directory (defaults to the Dockerfile's parent) |
| `args` | no | Map of `--build-arg` values |
| `nocache`, `pull`, `target`, `platform`, `labels`, ... | no | Any other Docker Engine API build option |

With `:build` set, the top-level `:image` is the **tag** the built image
receives rather than something to pull.

### Pipeline order

```
validate -> build|pull -> create -> start -> copy -> setup (steps) -> discover
```

`validate` covers the whole up-front pass: the disk-mount policy check, mount
normalization, and validation of steps and copies. The final `discover` phase
hydrates the `%Dockd.Instance{}` from `docker inspect`.

So a `step` can rely on a copied file being present.

## Error handling

Every function returns `:ok` or `{:ok, term()}` on success, and
`{:error, %ErrorMessage{}}` on failure — the struct from the
[`error_message`](https://hex.pm/packages/error_message) package, so dockd's
errors match the rest of your system rather than inventing their own shape.

```elixir
%ErrorMessage{
  code: :unprocessable_entity,
  message: "setup step failed: install",
  details: %{phase: :setup, exit_code: 1, output: "...", instance: %Dockd.Instance{}}
}
```

`code` says what kind of failure it was; `details.phase` says where in the
pipeline it happened. Both are useful because they are not one-to-one — three
different phases share `:unprocessable_entity`.

| Phase | `code` | Cause |
|-------|--------|-------|
| `:validate` | `:bad_request` | Unknown key, missing `image`, missing env var, malformed step/copy, relative build path, unusable `temp_root` |
| `:pull` | `:bad_gateway` | Registry pull failed |
| `:build` | `:unprocessable_entity` | `docker build` failed |
| `:create`, `:start` | `:bad_gateway` | Docker daemon refused the container |
| `:copy` | `:unprocessable_entity` | Source path doesn't exist on the host, or upload failed |
| `:setup` | `:unprocessable_entity` | A `step` exited non-zero, or a command/shell call failed |
| `:lifecycle` | `:bad_gateway` | `start/3` or `stop/3` failed on an existing container |
| `:destroy` | `:bad_gateway` | Stopping or removing a container failed |
| `:discover` | `:not_found` | Looking up or hydrating an instance from the daemon failed |

### What `details` carries

Only keys with something to report are present — an absent value is left out
rather than set to `nil`.

| Key | When | What it is |
|-----|------|------------|
| `:phase` | always | Where in the pipeline the failure happened |
| `:instance` | after a container exists | **The cleanup handle** — pass it to `Dockd.destroy/3` |
| `:step_results` | `:setup` | Output from the steps that ran before the failure |
| `:exit_code`, `:output` | `:setup` | The failing step's status and captured output |
| `:reason` | any Docker-originated failure | Docker's raw reason, unmodified |
| `:shell` | `shell_send/3` | The terminal handle, so the session can still be closed |

When a container was created before the failure, `details.instance` is a partial
instance you should pass to `Dockd.destroy/3` — without it, a failed apply
leaves a container behind.

No public function raises on bad input — every one returns
`{:ok, _} | {:error, %ErrorMessage{}}`, so a `FunctionClauseError` or
`ArgumentError` from your data is a bug in dockd rather than something to
rescue. (This is a promise about wrong *values*, not wrong *types*: passing
something that is not a keyword list as `opts` still raises from `Keyword`.)

```elixir
case Dockd.apply(spec, endpoint, false, %{}, temp_root) do
  {:ok, %Dockd.ApplyResult{instance: instance}} ->
    {:ok, %{output: out}} = Dockd.shell_command(instance, "uname -a", endpoint)
    IO.puts(out)
    instance

  {:error, %ErrorMessage{details: %{phase: :setup} = details}} ->
    IO.puts("setup failed (exit #{details.exit_code}):\n#{details.output}")
    Dockd.destroy(details.instance, endpoint)

  {:error, %ErrorMessage{details: details} = error} ->
    IO.puts("apply failed at #{details.phase}: #{error.message}")
    if instance = details[:instance], do: Dockd.destroy(instance, endpoint)
end
```

`ErrorMessage.to_string/1` renders the message with its details underneath, so
logging the struct shows Docker's status and body without you unpacking them.

### `shell_send/3` returns errors like everything else

`shell_send/3` used to answer `{:error, {reason, handle}}`, putting the terminal
handle in the error tuple. It now returns `{:error, %ErrorMessage{}}` like every
other function, with the handle at `details.shell` — you still need it to close
the session you just failed to write to:

```elixir
case Dockd.shell_send(shell, "pwd") do
  {:ok, {output, shell}} -> {output, shell}
  {:error, %ErrorMessage{details: %{shell: shell}}} -> Dockd.close_shell(shell)
end
```

## Tips

- **Keep spec maps in your repo** so collaborators get the same instance. A
  module of `@package` attributes, one per stack, is a good convention.
- **Prefer inherited `env` entries over hard-coded literals** for secrets -
  `env: ["GITHUB_TOKEN"]` reads the value from the `host_env` map you pass,
  without committing it. Pass only the names a spec should see: an empty
  `host_env` means it can reach nothing.
- **Check a spec map parses** with `Dockd.Spec.from_map/1` — it validates
  without touching Docker.
