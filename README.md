# Dockd

Dockd is an Elixir library for managing local Docker containers as named,
throwaway Linux workspaces ("instances"). You describe the environment you want
-- image, files, repos, setup commands -- and dockd builds it, runs it, and
tears it down on request.

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
| `disk_mount_enabled` | Whether host mounts, repo clones, file copies and host env are allowed. **No default** — an absent value used to mean `true` | `false`: allow none of it |
| `host_env` | The only values `:env` entries and `${VAR}` can resolve to | `%{}`: resolve nothing from the host |
| `temp_root` | Where repo clones and file copies are staged on the host | — |

If you want the conventional locations, name them yourself — that way the choice
is visible in your code:

```elixir
endpoint    = "unix:///var/run/docker.sock"
packages    = Path.join(System.user_home!(), ".dockd/packages")
temp_root   = System.tmp_dir!()
host_env    = %{"HOME" => System.user_home!()}
```

To get a real interactive shell in a new terminal window, use
`Dockd.Shell.open_window/6`; it launches `docker exec -it` in its own window so
your current terminal stays free. It takes the `docker` path and endpoint too, so
the window targets the same daemon the instance lives on rather than whatever the
new window's `PATH` and `DOCKER_HOST` happen to resolve to.

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

If you would rather build the spec first — to inspect or adjust it — use
`Dockd.Spec.new/3` and then `Dockd.apply/6`. `Spec.new/3` is the only
constructor, and it returns `{:ok, spec}` or a `:validate` error rather than
raising:

```elixir
{:ok, spec} = Dockd.Spec.new("debian:trixie", "builder", shell: "/bin/bash")
{:ok, result} = Dockd.apply(spec, endpoint, false, %{}, temp_root)
```

Both `shell_command/4` and `open_shell/3` are thin wrappers over
[`Docker.Terminal`](https://hexdocs.pm/docker/Docker.Terminal.html): use
`shell_command/4` for stateless one-shot commands (output + exit code),
and `open_shell` + `shell_send` + `close_shell` when commands must build
on each other (working directory, shell variables, etc.).

Other lifecycle functions, each taking the endpoint after its subject: `list/2`,
`get/3`, `start/3`, `stop/3`, `restart/3`, `running?/3`, `logs/3`, `inspect/3`,
`refresh/3`, `copy_to/5`.

### Instance options

These describe the workspace itself. They map one-to-one onto `Dockd.Spec`
fields (`Dockd.Spec.option_keys/0`).

The instance name is **not** among them: it is a positional argument of
`apply_image/7`, `Spec.new/3`, and `new_package/3`, because it is always
required. Dockd stores the short name you pass and derives the container name
`dockd-<name>` itself, so passing a name that already starts with `dockd-` is a
`:validate` error rather than a silent duplicate.

| Option | Default | Description |
|--------|---------|-------------|
| `:shell` | `"/bin/sh"` | Shell to use inside the container |
| `:description` | `nil` | Free-text description, stored on the spec |
| `:steps` | `[]` | Commands to run inside the container before it's ready |
| `:repos` | `[]` | Git repositories to clone on the host and upload into the container |
| `:copy` | `[]` | Files or directories to ship from the host into the container as one-way snapshots |
| `:mounts` | `[]` | Live host↔container shares - strings (`"host:container[:ro]"`) or structured maps (`%{type:, source:, target:, ...}`) |
| `:env` | `[]` | Container env entries - see below |
| `:labels` | `%{}` | Extra container labels, merged with the labels dockd manages |
| `:build` | `nil` | Build the image locally from a `%{dockerfile:, context:, args:, ...}` map instead of pulling |

Each setup step is a map with a `:step_name` and a `:cmd` (list of strings):

```elixir
%{step_name: "install git", cmd: ["apt-get", "install", "-y", "git"]}
```

In the Elixir API, each `:env` entry is one of:

| Shape | Behavior |
|-------|----------|
| `"FOO=bar"` | literal - passed through unchanged |
| `"FOO"` (no `=`) | read from `host_env`; **`:validate` error if absent from it** |
| `{"FOO", value: "bar"}` | literal, in tuple form |
| `{"FOO", default: "x"}` | `"x"` wins, **even when `host_env` has `FOO`** |
| `{"FOO", optional: true}` | read from `host_env`, silently drop the entry when absent |

"Inherit" means *from the `host_env` map you passed* — never from the calling
process. Note the `:default` row: an explicitly-passed default outranks
`host_env`, so ambient state cannot quietly override a value you wrote down.

The JSON package format uses a different, object-based shape for `env` -- see
[the `env` field reference](#env-list) below.

### Caller options

These tune the request rather than describing the workspace
(`Dockd.option_keys/0`). They share the same flat keyword list, are never stored
on the container, and unknown keys are rejected.

| Option | Description |
|--------|-------------|
| `:api_version` | Docker Engine API version to talk to |
| `:platform` | Target platform (e.g. `"linux/amd64"`) |
| `:networks` / `:network_mode` | Container networking |
| `:git_path` / `:git_env` | The `git` executable and the exact environment to run it in. Required when a spec has `:repos` |
| `:tar_path` / `:tar_env` / `:tar_extra_args` | The `tar` executable, its environment, and its archive flags. Required when a spec has `:copy` (or `:repos`, which uploads via `tar`) |
| `:container_staging_root` | Writable directory inside the container to stage uploads. Defaults to `"/tmp"` |

The host tooling entries are options rather than positional arguments because
only some specs need them — but a spec with `:repos` or `:copy` and no tooling is
a `:validate` error naming what is missing, never a `PATH` lookup. `:git_env`
always gets `GIT_TERMINAL_PROMPT=0` forced on, so a private URL fails fast
instead of blocking on a credential prompt nobody can see.

**Retired keys.** `:socket`, `:host`, `:disk_mount_enabled`, `:packages_path`,
`:dest_dir`, `:launcher_path`, and `:instance_name` used to live here and are now
positional arguments. Passing one is an error that names its replacement, so an
old call site fails loudly rather than reverting to an ambient default.

## Packages

A **package** is a JSON file that describes a complete instance - image, shell,
files to bring in, setup commands - so you can launch a reusable environment with
one call. Packages are the fastest way to share a "stack" (e.g. "Node 20 with
your toolchain preinstalled and a project directory mounted") with someone else: hand them the
file, they run `Dockd.apply_package(root, "./my-stack.json", …)`, and they get the same
container you do.

### A minimal package

Save this as `hello.json`:

```json
{
  "instance_name": "hello",
  "image": "busybox:1.37.0",
  "shell": "/bin/sh"
}
```

Setting `"shell"` is what keeps the container alive after it starts - see the
[`shell` field reference](#shell-string-optional) below.

Run it:

```elixir
{:ok, %Dockd.ApplyResult{instance: instance}} =
  Dockd.apply_package(packages, "./hello.json", endpoint, false, %{}, temp_root)

{:ok, %{output: out}} = Dockd.shell_command(instance, "uname -a", endpoint)
IO.puts(out)
Dockd.destroy(instance, endpoint)
```

That's the whole contract. The package's keys mirror the instance options
accepted by `Dockd.apply_image/7`, with `"image"` and `"instance_name"` both
required. You only specify what you need; everything else falls back to the same
defaults `Dockd.apply_image/7` uses.

### A realistic package

Here's a Python instance that clones a repo, copies a config file with locked-down
permissions, and runs an install step before handing you a shell:

```json
{
  "instance_name": "python-dev",
  "image": "python:3.12-slim",
  "shell": "/bin/bash",
  "env": [{"name": "GITHUB_TOKEN"}],
  "mounts": ["${PWD}:/instance"],
  "repos": [
    {
      "url": "https://github.com/psf/requests",
      "ref": "main",
      "dest": "/instance/requests"
    }
  ],
  "copy": [
    {
      "src": "${PWD}/config.yaml",
      "dest": "/etc/app/config.yaml",
      "mode": "0600"
    }
  ],
  "steps": [
    {"step_name": "install", "cmd": ["pip", "install", "-e", "/instance/requests"]}
  ]
}
```

Run it the same way:

```elixir
{:ok, %Dockd.ApplyResult{instance: instance}} =
  Dockd.apply_package(packages, "./python-instance.json", endpoint, true, host_env, temp_root)
```

### Field reference

The valid keys are `instance_name`, `description`, `image`, `shell`, `steps`,
`build`, `repos`, `copy`, `env`, `mounts`, and `labels`. `"instance_name"` and
`"image"` are required; the rest are optional. Unknown keys are rejected with a
`:validate` error so typos are caught early.

Three different things are called a name in a package, so they carry distinct
keys: `"instance_name"` at the top level names the container, `"step_name"`
names a setup step, and `"name"` inside an `env` entry is the environment
variable's own name.

#### `image` (string, required)

A Docker registry reference. With `"build"` set, this is the tag the built
image will receive instead.

```json
"image": "node:20-slim"
```

#### `description` (string, optional)

Free-text description of what the package provides. Carried on the spec; useful
when listing installed packages with `Dockd.list_packages/1`.

#### `labels` (map, optional)

Extra Docker labels to set on the container, merged with the labels dockd
manages for discovery.

```json
"labels": {"team": "platform"}
```

#### `shell` (string, optional)

Path inside the container that an interactive `docker exec -it` should launch.
Use the entrypoint of whatever tool you actually want - for an SSH-style shell,
`"/bin/bash"`; for a CLI tool that runs as a single binary, point directly at it
(e.g. `"/usr/local/bin/mytool"`).

Setting it also runs the container with an interactive shell as its command,
which is what keeps a container alive whose image would otherwise run to
completion and exit. **Omit it and an image like `busybox` exits immediately**,
so later `shell_command/3` calls fail with a Docker 409 ("container is not
running"). Set `"shell"` for any instance you intend to keep around.

#### `instance_name` (string, required)

The container's name, prefixed with `dockd-` if it isn't already. There is no
auto-generated default - a package without a non-empty `"instance_name"` is
rejected with a `:validate` error. Because the name is fixed by the package,
applying the same package twice concurrently will collide.

This is *not* the package's identity: a package is identified by its directory
name, which is what `Dockd.apply_package(root, "greeter", …)` resolves. The two are
independent, though scaffolding defaults them to the same value.

#### `env` (list)

Container environment variables. **In JSON, every entry must be an object** with
a non-empty `"name"`, plus at most one of `"value"`, `"default"`, or
`"optional"` (they are mutually exclusive). Bare strings like `"FOO=bar"` are
*not* valid here - that shape belongs to the Elixir keyword API described in
[Instance options](#instance-options).

| Shape | Behavior |
|-------|----------|
| `{"name": "FOO"}` | inherit from the host environment; **`:validate` error if unset** |
| `{"name": "FOO", "value": "bar"}` | literal - passed through unchanged |
| `{"name": "FOO", "default": "fallback"}` | inherit, fall back to the literal default if unset |
| `{"name": "FOO", "optional": true}` | inherit, silently drop the entry if unset |

`"value"` and `"default"` must be strings; `"optional"` must be a boolean.
`${VAR}` substitutions inside values still work - see
[Environment interpolation](#environment-interpolation).

```json
"env": [
  {"name": "NODE_ENV", "value": "development"},
  {"name": "API_KEY", "value": "${API_KEY}"},
  {"name": "GITHUB_TOKEN"},
  {"name": "LOG_LEVEL", "default": "info"},
  {"name": "SENTRY_DSN", "optional": true}
]
```

#### `mounts` (list)

Live host↔container shares. Each entry can be one of two shapes:

| Shape | Maps to | Use when |
|-------|---------|----------|
| `"host:container"` or `"host:container:ro"` | `HostConfig.Binds` (legacy string format) | the simple case - sharing one directory |
| `%{type:, source:, target:, ...}` map | `HostConfig.Mounts` (structured) | tmpfs, named volumes, or bind mounts with options |

Both sides see each other's writes (when applicable). The map shape mirrors
Docker's modern `--mount` flag - use `type: "bind"` with `:source` and `:target`,
or `type: "tmpfs"` with `:target`, etc.

```json
"mounts": [
  "${PWD}:/instance",
  "${HOME}/.ssh:/root/.ssh:ro",
  {"type": "tmpfs", "target": "/scratch"}
]
```

#### `repos` (list of maps)

Git repositories to clone on the **host** and upload into the container. Each
entry supports:

| Key | Required | Description |
|-----|----------|-------------|
| `url` | yes | Git URL - anything `git clone` accepts (HTTPS, SSH, file path) |
| `dest` | yes | Absolute path inside the container; the working tree appears here |
| `ref` | no | Branch or tag to check out (passed as `--branch`) |
| `depth` | no | Clone depth; defaults to `1` (shallow). Set to a larger integer for partial history |
| `history` | no | If `true`, ship the `.git` directory along with the working tree. Defaults to `false` |

Cloning runs on the host using your installed `git` binary, so HTTPS credentials,
SSH keys/agents, and `~/.gitconfig` are reused as-is - there's no need to bake
credentials into the image.

```json
"repos": [
  {"url": "https://github.com/octocat/Hello-World.git", "dest": "/instance/hello"},
  {"url": "git@github.com:my-org/private-repo", "ref": "v1.2", "dest": "/srv/app", "history": true}
]
```

#### `copy` (list of maps)

One-way snapshots from the host into the container. Each entry supports:

| Key | Required | Description |
|-----|----------|-------------|
| `src` | yes | Host path (file or directory). `${VAR}` substitutions apply |
| `dest` | yes | Absolute path inside the container; missing parent directories are created |
| `mode` | no | Permission bits applied with `chmod -R` after upload (e.g. `"0600"`) |
| `owner` | no | Ownership applied with `chown -R` after upload (e.g. `"root:root"`) |

Unlike `mounts`, the container receives its own copy - writes inside the container
do **not** propagate to the host. Use this when you want the container to be
isolated from later host edits, or when you want to copy in something Docker
volumes can't represent (a single file with tightened permissions, for example).

```json
"copy": [
  {"src": "${PWD}/config.yaml", "dest": "/etc/app/config.yaml", "mode": "0600"},
  {"src": "${HOME}/.ssh/id_ed25519", "dest": "/root/.ssh/id_ed25519", "mode": "0600", "owner": "root:root"}
]
```

When to choose `repos` vs. `copy` vs. `mounts`:

- **`mounts`** - the container should see live host changes, and vice versa.
- **`copy`** - the container needs an isolated snapshot, and the host should be
  unaffected by container writes.
- **`repos`** - the source of truth lives in git and shouldn't have to be on the
  host already.

#### `steps` (list of maps)

Commands to run inside the container after files have been put in place but before
the instance is considered ready. Each step is a map:

| Key | Required | Description |
|-----|----------|-------------|
| `step_name` | yes | Human-readable name shown in errors and `step_results` |
| `cmd` | yes | Argv list (e.g. `["npm", "install"]`) - never a single string |
| `env` | no | Per-step env entries, on top of the container's env |
| `workdir` | no | Working directory for this step |
| `user` | no | User to run the step as |

A step exiting non-zero halts the prepare with a `:setup` error that carries the
captured output and exit code. Earlier steps' results are preserved in
`error.instance.step_results`.

```json
"steps": [
  {"step_name": "install deps", "cmd": ["npm", "install"], "workdir": "/instance"},
  {"step_name": "run migrations", "cmd": ["npx", "prisma", "migrate", "deploy"]}
]
```

#### `build` (map)

Build the image locally from a Dockerfile instead of pulling. Mirrors Docker
Compose's `build:` block. Setting `"build"` triggers the build path; absence
triggers the pull path.

| Key | Required | Description |
|-----|----------|-------------|
| `dockerfile` | yes | Path to a Dockerfile, or to a directory containing one |
| `context` | no | Build context directory (defaults to the Dockerfile's parent) |
| `args` | no | Map of `--build-arg` values (forwarded to Docker's `buildargs` field) |
| `nocache`, `pull`, `target`, `platform`, `labels`, ... | no | Any other Docker Engine API build option |

With `"build"` set, the top-level `"image"` is the **tag** the built image
receives rather than something to pull.

```json
"build": {
  "dockerfile": "./Dockerfile",
  "context": "./",
  "args": {"MIX_ENV": "prod"},
  "nocache": true
}
```

Relative `dockerfile` and `context` paths resolve against the **package
directory**, not the current working directory, so a package that ships its own
Dockerfile stays self-contained and can be installed anywhere.

#### Connection options

`socket`, `host`, `api_version`, `platform`, `networks`, `network_mode` - passed
through to the Docker connection. Default to your daemon's defaults; only set
when you need to talk to a non-default daemon.

### Pipeline order

Phases run in this order:

```
validate -> build|pull -> create -> start -> fetch (repos) -> copy -> setup (steps) -> discover
```

`validate` covers the whole up-front pass: the disk-mount policy check, `${VAR}`
expansion, mount normalization, and validation of steps, repos and copies. The
final `discover` phase hydrates the `%Dockd.Instance{}` from `docker inspect`.

So a `step` can rely on a cloned repo or copied file being present, and a `copy`
can land on top of a directory that was just created by a `repo` clone.

### Environment interpolation

Every string value (not key) is recursively scanned for `${VAR}` references and
substituted from the `host_env` map you pass — **not** from your shell's
environment. A package can only reach values you handed it, so `%{}` substitutes
nothing and a package that needs `${HOME}` gets it only if you passed `"HOME"`:

- `${HOME}` - required: a name absent from `host_env` produces a `:validate`
  error pointing at the JSON path (e.g. `$.copy[0].src`).
- `${HOME:-default}` - fall back to a literal default when the variable is unset.
- Multiple references in one string are all substituted (`"${USER}@${HOST}"`).
- Substitution happens before validation, so a `${VAR}` inside a list or nested
  map is fine.

```elixir
# ${PWD} and ${LOG_LEVEL} below resolve only because they are passed in.
{:ok, result} =
  Dockd.apply_package(packages, "node-app", endpoint, true,
    %{"PWD" => File.cwd!(), "LOG_LEVEL" => "debug"}, temp_root)
```

```json
{
  "instance_name": "node-app",
  "image": "node:20-slim",
  "mounts": ["${PWD}:/instance"],
  "env": [{"name": "LOG_LEVEL", "value": "${LOG_LEVEL:-info}"}]
}
```

### Running a package

Two entry points:

```elixir
# A path on disk - typical for project-local packages. `packages` is unused for a
# path reference, but still passed so the argument list keeps one shape.
{:ok, %Dockd.ApplyResult{instance: instance}} =
  Dockd.apply_package(packages, "./packages/python.json", endpoint, false, %{}, temp_root)

# A bare name - resolves to <packages>/webapp/package.json.
{:ok, %Dockd.ApplyResult{instance: instance}} =
  Dockd.apply_package(packages, "webapp", endpoint, false, %{}, temp_root)
```

A package's `${VAR}` references resolve against the `host_env` you pass, so a
package can only reach values you handed it:

```elixir
# This package interpolates ${HOME}; nothing else about your environment is visible.
{:ok, result} =
  Dockd.apply_package(packages, "webapp", endpoint, true,
    %{"HOME" => System.user_home!()}, temp_root)
```

To read a package into a `Dockd.Spec` without applying it — to inspect or adjust
it first — use `Dockd.load_package_spec/3`, then `Dockd.apply/6`.

### Installed packages

Package names resolve against the `root` you pass. There is no configured
packages root: no `DOCKD_PACKAGES_PATH`, no `config :dockd, packages_path:`, no
`~/.dockd/packages` fallback. `~/.dockd/packages` remains a perfectly good
choice — it is just yours to make and to write down.

Package sets live in their own directory trees. `Dockd.install_packages/3`
copies every `packages/<name>/` directory the source ships with into `root`, from
either a git repository or a local directory:

```elixir
# From a local directory - any existing directory on disk takes this path.
{:ok, ["python", "webapp"]} = Dockd.install_packages(packages, "./my-recipes")

# From a remote repository - anything `git clone` accepts, plus the
# `github.com/user/repo` shorthand. A clone needs somewhere to stage and a git
# to run, so both are passed explicitly.
{:ok, ["python", "webapp"]} =
  Dockd.install_packages(packages, "github.com/me/recipes",
    staging_root: temp_root,
    git_path: "/usr/bin/git",
    git_env: %{"HOME" => System.user_home!()},
    ref: "v1.2.0"
  )
```

`git_env` is the whole environment `git` runs in. That is what makes credentials
an explicit decision: pass `HOME` and `SSH_AUTH_SOCK` when a clone needs your
`~/.gitconfig` or SSH agent, and omit them to clone in isolation. Dockd always
forces `GIT_TERMINAL_PROMPT=0`, so a private URL you have no credentials for
fails immediately instead of hanging on an invisible prompt.

The source must have a top-level `packages/` directory (override with
`:packages_subdir`); otherwise you get a `:fetch` error. An existing target
directory is replaced.

See what's installed:

```elixir
Dockd.list_packages(packages)
#=> [%{name: "webapp", path: "...", spec: {:ok, %Dockd.Spec{}}}]
```

Each entry's `:spec` is itself a result tuple, so one malformed `package.json`
reports its own parse error instead of hiding the rest.

### Scaffolding a package

You don't have to write those files by hand. `Dockd.new_package/3` writes them
for you. The path you pass **is** the package directory, and the instance name is
its own argument — it used to default to the directory's basename, which for a
relative path like `"."` really meant your current working directory:

```elixir
{:ok, %{instance_name: "greeter", files: files}} =
  Dockd.new_package("./my-recipes/packages/greeter", "greeter",
    image: "dockd-greeter:1",
    from: "busybox:1.37.0",
    shell: "/bin/sh",
    env: [{"API_KEY", optional: true}],
    steps: [%{step_name: "verify", cmd: ["sh", "-c", "test -f /etc/greeting"]}]
  )
```

That writes `package.json` and a `Dockerfile`. Every scaffolded package builds
its own image, so `image` is the tag the build produces and `from` is the
Dockerfile's base image. Only the keys you pass are written - there is nothing
to delete afterwards:

```json
{
  "instance_name": "greeter",
  "image": "dockd-greeter:1",
  "shell": "/bin/sh",
  "build": {
    "dockerfile": "Dockerfile"
  },
  "env": [
    {
      "name": "API_KEY",
      "optional": true
    }
  ],
  "steps": [
    {
      "step_name": "verify",
      "cmd": ["sh", "-c", "test -f /etc/greeting"]
    }
  ]
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `:instance_name` | directory basename | Container name the package creates |
| `:image` | `dockd-<instance_name>:latest` | Tag the build produces |
| `:from` | `debian:trixie` | Base image for the generated Dockerfile |
| `:dockerfile` | - | A complete Dockerfile body, instead of `:from` |
| `:build` | `{}` | Extra build keys merged over `{"dockerfile": "Dockerfile"}` |
| `:force` | `false` | Replace an existing directory |

`:description`, `:shell`, `:env`, `:mounts`, `:repos`, `:copy`, `:steps` and
`:labels` are written straight through. `env` accepts the Elixir shapes and is
translated into the JSON object form for you.

Scaffolding refuses to touch an existing directory unless you pass
`force: true`, and validates the document before writing anything - an invalid
call leaves nothing behind. Relative `build` paths resolve against the package
directory, so the result keeps working after `install_packages/3` copies it
elsewhere:

```elixir
{:ok, ["greeter"]} = Dockd.install_packages(packages, "./my-recipes")

{:ok, %Dockd.ApplyResult{instance: instance}} =
  Dockd.apply_package(packages, "greeter", endpoint, false, %{}, temp_root)
```

To add your own installed package by hand, place a directory at
`<root>/<name>/` containing `package.json` and any referenced support files, then
call `Dockd.apply_package(root, "name", ...)`.

### A package that builds its own image

A package is just data, so a package that ships a Dockerfile alongside its
`package.json` is enough to define, build, and run a custom image - no Elixir
code involved. Lay the source out as a package set:

```
my-recipes/
└── packages/
    └── greeter/
        ├── package.json
        └── Dockerfile
```

```json
{
  "instance_name": "greeter",
  "description": "busybox with a baked-in greeting",
  "image": "dockd-greeter:1",
  "shell": "/bin/sh",
  "build": {
    "dockerfile": "./Dockerfile",
    "args": {"GREETING": "hello"}
  },
  "steps": [
    {"step_name": "verify", "cmd": ["sh", "-c", "test -f /etc/greeting"]}
  ]
}
```

```dockerfile
FROM busybox:1.37.0
ARG GREETING=unset
RUN echo "$GREETING" > /etc/greeting
```

Install it and apply it by name. The `Dockerfile` is copied in alongside the
`package.json`, and `"image"` becomes the tag of the image that gets built:

```elixir
{:ok, ["greeter"]} = Dockd.install_packages(packages, "./my-recipes")

{:ok, %Dockd.ApplyResult{instance: instance}} =
  Dockd.apply_package(packages, "greeter", endpoint, false, %{}, temp_root)

{:ok, %{output: out}} = Dockd.shell_command(instance, "cat /etc/greeting", endpoint)
IO.puts(out)  #=> "hello"
```

The build runs before the container is created, so setup `steps` and `copy`
entries operate on the freshly built image.

The lookup rule is lexical: a string with no `/` and no `.json` suffix is a
package name; anything else is a path.

### Error handling

Every failure returns `{:error, %Dockd.Error{}}`. The `:phase` field tells you
where things went wrong:

| Phase | Cause |
|-------|-------|
| `:validate` | Bad JSON, unknown key, missing `image`, missing env var, malformed step/repo/copy |
| `:generate` | Scaffolding failed - target directory exists, or a file could not be written |
| `:pull` | Registry pull failed |
| `:build` | `docker build` failed |
| `:create`, `:start` | Docker daemon refused the container |
| `:fetch` | `git clone` failed, package install failed, or upload to the container failed |
| `:copy` | Source path doesn't exist on the host, or upload failed |
| `:setup` | A `step` exited non-zero - `error.exit_code` and `error.output` are populated |
| `:lifecycle` | `start/3` or `stop/3` failed on an existing container |
| `:destroy` | Stopping or removing a container failed |
| `:discover` | Looking up or hydrating an instance from the daemon failed |

When a container was created before the failure, `error.instance` is a partial
instance you should pass to `Dockd.destroy/3` to clean up.

No public function raises on bad input — every one returns
`{:ok, _} | {:error, %Dockd.Error{}}` with a phase tag, so a `FunctionClauseError`
or `ArgumentError` from your data is a bug in dockd rather than something to
rescue.

```elixir
case Dockd.apply_package(packages, "./mystack.json", endpoint, false, %{}, temp_root) do
  {:ok, %Dockd.ApplyResult{instance: instance}} ->
    {:ok, %{output: out}} = Dockd.shell_command(instance, "uname -a", endpoint)
    IO.puts(out)
    instance

  {:error, %Dockd.Error{phase: :setup, exit_code: code, output: output, instance: instance}} ->
    IO.puts("setup failed (exit #{code}):\n#{output}")
    if instance, do: Dockd.destroy(instance, endpoint)

  {:error, error} ->
    IO.puts("apply failed at #{error.phase}: #{error.message}")
    if error.instance, do: Dockd.destroy(error.instance, endpoint)
end
```

### Tips

- **Keep packages in your repo** so collaborators get the same instance.
  `./packages/<stack>.json` is a good convention.
- **Prefer inherited `env` entries over hard-coded literals** for secrets -
  `"env": [{"name": "GITHUB_TOKEN"}]` reads the value from the `host_env` map you
  pass, without committing it. Pass only the names a package should see: an empty
  `host_env` means it can reach nothing.
- **Use `${PWD}` and `${HOME}`** in `mounts`/`copy` so the same package works
  for everyone on the team.
- **Check an installed package parses** with `Dockd.list_packages/1`, whose
  per-package `:spec` is `{:ok, spec}` or `{:error, error}` - it validates
  without touching Docker.
