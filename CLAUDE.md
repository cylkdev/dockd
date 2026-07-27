# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
mix compile              # Compile
mix test                 # Run all tests (integration tests require a running Docker daemon)
mix test path/to/test.exs          # Run a single test file
mix test path/to/test.exs:42       # Run a single test by line number
mix format               # Format code
```

## Architecture

Dockd is a plain Elixir library that manages local Docker containers ("instances") as named workspaces. It depends on a sibling `docker` library at `../docker` which wraps the Docker Engine API over HTTP via a Unix socket.

### Stateless, Docker-as-source-of-truth

Dockd holds no state of any kind. There is no application module, no supervision tree (`mix.exs` has no `mod:` key), no GenServers, no ETS tables, no local stores, and nothing derived is cached. Every container created via `Dockd.apply/2` carries two labels that make it self-describing:

- `org.dockd.instance` = `"true"` — discovery marker
- `org.dockd.instance.name` = `<instance_name>` — human-readable name

After a crash or restart, `Dockd.list/1` rediscovers every managed instance by filtering Docker on the marker label, and `Dockd.get/2` fetches a single instance by name. The `%Dockd.Instance{}` struct is a view of the live container — hydrated on demand from `docker inspect`, never long-lived.

Every read goes to the live daemon. Nothing dockd writes is later trusted as a cache.

### Type separation

| Module | Role |
|---|---|
| `Dockd.Spec` | Declarative request. Pure input — consumed by `apply/2`, then discarded. |
| `Dockd.Instance` | View of an existing container. Hydrated from `find_container/2`. |
| `Dockd.ApplyResult` | One call's outcome: `%{instance, step_results}`. |

Caller-runtime context — Docker daemon connection (`:socket`, `:host`, `:platform`, …) and the policy flag `:disk_mount_enabled` — lives in per-call `opts`. It never touches a struct or a container label.

### Naming: three distinct "name" fields

Three unrelated things could each be called a name, so each has its own key. Do not collapse them, and be careful with find-and-replace across `"name"`:

| Key | Where | Means |
|---|---|---|
| `instance_name` | top level of a package / `Spec` field / `apply/2` option | The container's name, prefixed to `dockd-<value>` and used by `get/2` and `destroy/2` |
| `step_name` | inside a `steps` entry | Display name for one setup step; appears in `:setup` errors and on `StepResult` |
| `name` | inside an `env` entry | The environment variable's own name |

A package's *identity* is none of these — it is the package's directory name, which is what `Dockd.apply_package("greeter")` resolves via `Packages.resolve_path/2`.

`%Dockd.Instance{}` keeps a plain `:name` field: it is a different struct and `instance.name` is already unambiguous.

The old `"name"` (top level) and `"label"` (step) keys were renamed and are not accepted; both produce a `:validate` error naming the replacement.

### Provisioning pipeline

`Dockd.Provisioner.run/2` takes a `Spec` plus per-call `opts` and runs a sequential pipeline: **enforce disk-mount policy** -> **expand env** -> **normalize mounts** -> **validate source** -> **normalize steps/repos/copies** -> **build or pull image** -> **create container** -> **start container** -> **fetch repos** -> **copy host files** -> **run setup steps** -> **hydrate Instance**. Each phase is tagged (`:validate`, `:build`, `:pull`, `:create`, `:start`, `:fetch`, `:copy`, `:setup`, `:discover`) so errors report where the failure occurred. When a container was created before the failure, the error carries a hydrated `Dockd.Instance` (and any captured `step_results`) so the caller can clean up with `Dockd.destroy/2`.

Outside the pipeline, `Dockd.Error` also uses `:lifecycle` (`start/2`/`stop/2`), `:destroy`, and `:generate` (scaffolding a package to disk).

The image source is determined by `Spec.build`: when set, the image is built locally via `Docker.build_image/5`; otherwise it is pulled from a registry via `Docker.pull_image/3`.

### Key modules

- `Dockd` — the entire public API in one module. `apply/2`, `apply_package/2`, `install_packages/2`, `new_package/2`, `list_packages/1`, `delete_package/2`, `list/1`, `get/2`, `destroy/2`, `start/2`, `stop/2`, `restart/2`, `running?/2`, `logs/2`, `inspect/2`, `refresh/2`, `shell_command/3`, `open_shell/2`, `shell_send/3`, `close_shell/2`, `copy_to/3`, `list_temp_files/1`, `delete_temp_files/1`, `info/1`, `option_keys/0`. `install_packages/2` dispatches on the reference: an existing local directory installs from disk, anything else is cloned as a git URL
- `Dockd.Spec` — declarative request type; `from_opts/2`, `from_attrs/1`, `option_keys/0`, `prefix_name/1`, `short_name/1`
- `Dockd.Spec.Parser` / `.Interpolator` / `.Normalizer` — the JSON-package pipeline: read+parse, `${VAR}` substitution, then attribute normalization
- `Dockd.Spec.Encoder` — the reverse direction: turns caller options into a `package.json` document and pretty-prints it. Pure; `Dockd.Packages.new/2` does the writing
- `Dockd.Instance` — view type; `from_inspect/1`, `managed_labels/1`, `short_name/1`
- `Dockd.Provisioner` — the create-an-Instance pipeline
- `Dockd.Packages` — package storage: reference resolution, listing, install from git or a local path, and `new/2` to scaffold a package's files
- `Dockd.ApplyResult` — `%{instance, step_results}` returned by `apply/2`
- `Dockd.Git` — clones git repos on the host and uploads via `Docker.put_archive/4`
- `Dockd.FileCopy` — tars host files/dirs and uploads via `Docker.put_archive/4`; also owns the `<system_tmp>/dockd/` staging-dir housekeeping
- `Dockd.Shell` — opens a real interactive TTY for a **human** in a new OS terminal window, so the calling program never surrenders its controlling terminal. Distinct from `Dockd.open_shell/2`, which is the programmatic, non-TTY form
- `Dockd.Ssh` / `Dockd.Ssh.DockerDialStdio` — the remote-daemon path. Renders and installs a wrapper around `docker system dial-stdio` that synthesizes an HTTP 502 when the remote command fails, so the client sees a typed error rather than an opaque EOF
- `Dockd.Error` — phase-tagged error struct with optional `:instance` and `:step_results`
- `Dockd.StepResult` — captured output and exit code from a single setup step

### Configuration

The packages root resolves from `opts[:packages_path]`, then `DOCKD_PACKAGES_PATH`, then `config :dockd, packages_path: ...`, defaulting to `~/.dockd/packages`. It is read in `Dockd.Packages.packages_root/1`. Host-side staging always lives at `<system_tmp>/dockd/` and is not configurable.

### Docker dependency

The `Docker` module (at `../docker`) provides the low-level API calls. Key functions used by dockd: `pull_image/3`, `build_image/5`, `create_container/4`, `start_container/2`, `stop_container/2`, `delete_container/3`, `put_archive/4`, `list_containers/2`, `find_container/2`, `container_logs/3`, `container_running?/2`, and the `Docker.Terminal` family (`run_with_status/3`, `open/2`, `command/3`, `close/1`).

### Testing

Pure unit tests (no Docker daemon required): `test/dockd/spec_test.exs`, `test/dockd/instance_test.exs`, `test/dockd/spec/*_test.exs` (including `encoder_test.exs`), `test/dockd/apply_opts_test.exs`, `test/dockd/shell_arg_test.exs`, `test/dockd/shell_test.exs`, `test/dockd/ssh_test.exs`, `test/dockd/ssh/*_test.exs`, `test/dockd/open_shell_script_test.exs`.

`test/dockd/packages_test.exs` is mixed: the scaffolding, listing and local-install tests are pure, while `install_from_git/2` tests are tagged `:integration`.

Integration tests requiring a running Docker daemon: `test/dockd_test.exs`, `test/dockd/env_test.exs`, `test/dockd/packages_test.exs`. They use `busybox:1.37.0` as the test image. With no daemon reachable these fail with `:endpoint_not_resolved`.

Test fixtures (e.g. a minimal Dockerfile) live in `test/fixtures/`.
