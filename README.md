# Dockd

Dockd gives you a throwaway Linux terminal inside a Docker container with a
single command. When you're done, it cleans everything up automatically.

## Prerequisites

- [Elixir](https://elixir-lang.org/install.html) 1.17 or later
- [Docker](https://docs.docker.com/get-docker/) installed and running

Verify Docker is running:

```sh
docker info
```

If you see connection errors, start Docker Desktop (Mac/Windows) or the Docker daemon (Linux).

## Quick Start

```sh
mix dockd
```

This pulls a Debian Linux image, starts a container, and prints a command like:

```
Container is ready!

Connect to it by running this command in another terminal:

    docker exec -it dockd-123 /bin/bash
```

Open a second terminal, paste that command, and you're inside a Linux shell. Install packages, run scripts, experiment freely -- nothing you do inside the container affects your computer.

When you're done, go back to the first terminal and press Enter. The container is stopped and deleted automatically.

## Using a Different Image

Pass any Docker image as an argument:

```sh
mix dockd ubuntu:24.04
mix dockd alpine:latest
mix dockd node:20-slim
```

## Elixir API

For programmatic use, Dockd exposes three functions:

```elixir
# Start a container with setup steps
{:ok, session} =
  Dockd.prepare("debian:trixie",
    shell: "/bin/bash",
    steps: [
      %{label: "update", cmd: ["apt-get", "update"]},
      %{label: "install curl", cmd: ["apt-get", "install", "-y", "curl"]}
    ]
  )

# Get the command to connect
session.shell_command
#=> "docker exec -it dockd-123 /bin/bash"

# Clean up when done
Dockd.destroy(session)
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `:shell` | `"/bin/sh"` | Shell to use inside the container |
| `:name` | auto-generated | Container name |
| `:steps` | `[]` | Commands to run inside the container before it's ready |
| `:repos` | `[]` | Git repositories to clone on the host and upload into the container |
| `:copy` | `[]` | Files or directories to ship from the host into the container as one-way snapshots |
| `:mounts` | `[]` | Live host↔container shares - strings (`"host:container[:ro]"`) or structured maps (`%{type:, source:, target:, ...}`) |
| `:env` | `[]` | Container env entries - literal `"K=V"`, bare `"FOO"` (inherits from host), or `{"FOO", default: "x"}` |
| `:build` | `nil` | Build the image locally from a `%{dockerfile:, context:, args:, ...}` map instead of pulling |
| `:api_version` | daemon default | Docker Engine API version to talk to |

Each setup step is a map with a `:label` and a `:cmd` (list of strings):

```elixir
%{label: "install git", cmd: ["apt-get", "install", "-y", "git"]}
```

## Packages

A **package** is a JSON file that describes a complete workspace - image, shell,
files to bring in, setup commands - so you can launch a reusable environment with
one call. Packages are the fastest way to share a "stack" (e.g. "Node 20 with
claude-code installed and `~/.claude` mounted") with someone else: hand them the
file, they run `Dockd.prepare_package("./my-stack.json")`, and they get the same
container you do.

### A minimal package

Save this as `hello.json`:

```json
{
  "image": "busybox:1.37.0"
}
```

Run it:

```elixir
{:ok, session} = Dockd.prepare_package("./hello.json")
IO.puts(session.shell_command)
#=> docker exec -it dockd-1 /bin/sh
Dockd.destroy(session)
```

That's the whole contract. The package's keys mirror the options accepted by
`Dockd.prepare/2`, plus a top-level `"image"` field that becomes the first
positional argument. You only specify what you need; everything else falls back
to the same defaults `Dockd.prepare/2` uses.

### A realistic package

Here's a Python workspace that clones a repo, copies a config file with locked-down
permissions, and runs an install step before handing you a shell:

```json
{
  "image": "python:3.12-slim",
  "shell": "/bin/bash",
  "env": ["GITHUB_TOKEN"],
  "mounts": ["${PWD}:/workspace"],
  "repos": [
    {
      "url": "https://github.com/psf/requests",
      "ref": "main",
      "dest": "/workspace/requests"
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
    {"label": "install", "cmd": ["pip", "install", "-e", "/workspace/requests"]}
  ]
}
```

Run it the same way:

```elixir
{:ok, session} = Dockd.prepare_package("./python-workspace.json")
```

### Field reference

Every field is optional except `"image"`. Unknown keys are rejected with a
`:validate` error so typos are caught early.

#### `image` (string, required)

A Docker registry reference. With `"dockerfile"` set, this is the tag the built
image will receive instead.

```json
"image": "node:20-slim"
```

#### `shell` (string, default `"/bin/sh"`)

Path inside the container that an interactive `docker exec -it` should launch.
Use the entrypoint of whatever tool you actually want - for an SSH-style shell,
`"/bin/bash"`; for a CLI tool that runs as a single binary, point directly at it
(e.g. `"claude"`).

#### `name` (string, default auto-generated)

Container name. Defaults to `"dockd-<unique>"`. Setting it makes the container
easier to find with `docker ps`, but two simultaneous prepares of the same
package will collide on the name.

#### `env` (list)

Container environment variables. Each entry can be one of three shapes:

| Shape | Behavior |
|-------|----------|
| `"FOO=bar"` | literal - passed through unchanged |
| `"FOO"` (no `=`) | inherit from the host environment; **`:validate` error if unset** |
| `["FOO", {"default": "fallback"}]` (Elixir tuple `{"FOO", default: "fallback"}`) | inherit, fall back to the literal default if unset |

`${VAR}` substitutions inside values still work - see
[Environment interpolation](#environment-interpolation).

```json
"env": [
  "NODE_ENV=development",
  "API_KEY=${API_KEY}",
  "GITHUB_TOKEN",
  "ANTHROPIC_API_KEY"
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
  "${PWD}:/workspace",
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
  {"url": "https://github.com/octocat/Hello-World.git", "dest": "/workspace/hello"},
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

Unlike `binds`, the container receives its own copy - writes inside the container
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
the workspace is considered ready. Each step is a map:

| Key | Required | Description |
|-----|----------|-------------|
| `label` | yes | Human-readable name shown in errors and `step_results` |
| `cmd` | yes | Argv list (e.g. `["npm", "install"]`) - never a single string |
| `env` | no | Per-step env entries, on top of the container's env |
| `workdir` | no | Working directory for this step |
| `user` | no | User to run the step as |

A step exiting non-zero halts the prepare with a `:setup` error that carries the
captured output and exit code. Earlier steps' results are preserved in
`error.session.step_results`.

```json
"steps": [
  {"label": "install deps", "cmd": ["npm", "install"], "workdir": "/workspace"},
  {"label": "run migrations", "cmd": ["npx", "prisma", "migrate", "deploy"]}
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

```json
"build": {
  "dockerfile": "./Dockerfile",
  "context": "./",
  "args": {"MIX_ENV": "prod"},
  "nocache": true
}
```

#### Connection options

`socket`, `host`, `api_version`, `platform`, `networks`, `network_mode` - passed
through to the Docker connection. Default to your daemon's defaults; only set
when you need to talk to a non-default daemon.

### Pipeline order

Phases run in this order:

```
validate -> build|pull -> create -> start -> fetch (repos) -> copy -> setup (steps) -> ready
```

So a `step` can rely on a cloned repo or copied file being present, and a `copy`
can land on top of a directory that was just created by a `repo` clone.

### Environment interpolation

Every string value (not key) is recursively scanned for `${VAR}` references and
substituted from your shell's environment:

- `${HOME}` - required: missing variables produce a `:validate` error pointing
  at the JSON path (e.g. `$.copy[0].src`).
- `${HOME:-default}` - fall back to a literal default when the variable is unset.
- Multiple references in one string are all substituted (`"${USER}@${HOST}"`).
- Substitution happens before validation, so a `${VAR}` inside a list or nested
  map is fine.

```json
{
  "image": "node:20-slim",
  "binds": ["${PWD}:/workspace"],
  "env": ["LOG_LEVEL=${LOG_LEVEL:-info}"]
}
```

### Running a package

Two entry points:

```elixir
# A path on disk - typical for project-local packages.
{:ok, session} = Dockd.prepare_package("./packages/python.json")

# A bare name - resolves to priv/packages/<name>.json shipped with dockd.
{:ok, session} = Dockd.prepare_package("claude_code_live_workspace")
```

`prepare_package/1` is a thin wrapper: it calls `Dockd.Package.load/1` to read
and validate the file, then `Dockd.prepare/2` with the resulting options. If you
want to inspect or tweak the loaded options first:

```elixir
{:ok, {image, opts}} = Dockd.Package.load("./packages/python.json")
opts = Keyword.put(opts, :name, "scratch")
{:ok, session} = Dockd.prepare(image, opts)
```

### Bundled packages

Packages shipped in `priv/packages/` are addressable by their filename stem.
Names are tied 1:1 to the JSON files on disk, so `ls priv/packages` is the
canonical catalog of presets. The bundled presets:

| Name | What you get |
|------|--------------|
| `"claude_code_live_workspace"` | Live bind of `${PWD}` at `/workspace`, shared `~/.claude` for OAuth - claude's edits land back on the host. |
| `"claude_code_isolated_workspace"` | One-way snapshot of `${PWD}` at `/workspace/project`, plus a single `~/dockd-output → /workspace/output` bind - host source stays pristine, results land in one named directory. Uses `ANTHROPIC_API_KEY` rather than shared OAuth. |
| `"claude_code_repo_workspace"` | Shallow-clones `${DOCKD_REPO_URL}` (optional `${DOCKD_REPO_REF}`, default `main`) into `/workspace/repo`, plus a single `~/dockd-output → /workspace/output` bind. Host's `git` credentials handle the clone; `ANTHROPIC_API_KEY` is required and `GITHUB_TOKEN` is forwarded if set. |

To add your own bundled package, drop a JSON file in that directory (or its
equivalent in your dependent project's priv) and reference it with
`Dockd.prepare_package("my_name")`. Pick a filename that describes the
workspace shape - `python_test_runner.json`, `node_with_postgres.json`, etc. -
so collaborators can tell presets apart at a glance.

The lookup rule is purely lexical: a string with no `/` and no `.json` suffix
is a bundled name; anything else is a path. This keeps `Package.load/1`
deterministic and stateless - the BEAM atom table never grows from preset
names.

### Error handling

Every failure returns `{:error, %Dockd.Error{}}`. The `:phase` field tells you
where things went wrong:

| Phase | Cause |
|-------|-------|
| `:validate` | Bad JSON, unknown key, missing `image`, missing env var, malformed step/repo/copy |
| `:pull` | Registry pull failed |
| `:build` | `docker build` failed |
| `:create`, `:start` | Docker daemon refused the container |
| `:fetch` | `git clone` failed, or upload to the container failed |
| `:copy` | Source path doesn't exist on the host, or upload failed |
| `:setup` | A `step` exited non-zero - `error.exit_code` and `error.output` are populated |

When a container was created before the failure, `error.session` is a partial
session you should pass to `Dockd.destroy/1` to clean up.

```elixir
case Dockd.prepare_package("./mystack.json") do
  {:ok, session} ->
    IO.puts(session.shell_command)
    session

  {:error, %Dockd.Error{phase: :setup, exit_code: code, output: output, session: session}} ->
    IO.puts("setup failed (exit #{code}):\n#{output}")
    if session, do: Dockd.destroy(session)

  {:error, error} ->
    IO.puts("prepare failed at #{error.phase}: #{error.message}")
    if error.session, do: Dockd.destroy(error.session)
end
```

### Tips

- **Keep packages in your repo** so collaborators get the same workspace.
  `./packages/<stack>.json` is a good convention.
- **Prefer bare-name `env` entries over hard-coded literals** for secrets -
  `"env": ["GITHUB_TOKEN"]` reads from the host without committing the value.
- **Use `${PWD}` and `${HOME}`** in `mounts`/`copy` so the same package works
  for everyone on the team.
- **Test a package locally** with `Dockd.Package.load("./mystack.json")` before
  preparing - load runs all validation without touching Docker.
