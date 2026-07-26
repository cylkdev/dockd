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
- `org.dockd.instance.name` = `<workspace_name>` — human-readable name

After a crash or restart, `Dockd.list/1` rediscovers every managed instance by filtering Docker on the marker label, and `Dockd.get/2` fetches a single instance by name. The `%Dockd.Instance{}` struct is a view of the live container — hydrated on demand from `docker inspect`, never long-lived.

Every read goes to the live daemon. Nothing dockd writes is later trusted as a cache.

### Type separation

| Module | Role |
|---|---|
| `Dockd.Spec` | Declarative request. Pure input — consumed by `apply/2`, then discarded. |
| `Dockd.Instance` | View of an existing container. Hydrated from `find_container/2`. |
| `Dockd.ApplyResult` | One call's outcome: `%{instance, step_results}`. |

Caller-runtime context — Docker daemon connection (`:socket`, `:host`, `:platform`, …) and the policy flag `:disk_mount_enabled` — lives in per-call `opts`. It never touches a struct or a container label.

### Provisioning pipeline

`Dockd.Provisioner.run/2` takes a `Spec` plus per-call `opts` and runs a sequential pipeline: **enforce disk-mount policy** -> **expand env** -> **normalize mounts** -> **validate source** -> **normalize steps/repos/copies** -> **build or pull image** -> **create container** -> **start container** -> **fetch repos** -> **copy host files** -> **run setup steps** -> **hydrate Instance**. Each phase is tagged (`:validate`, `:build`, `:pull`, `:create`, `:start`, `:fetch`, `:copy`, `:setup`, `:discover`) so errors report where the failure occurred. When a container was created before the failure, the error carries a hydrated `Dockd.Instance` (and any captured `step_results`) so the caller can clean up with `Dockd.destroy/2`.

The image source is determined by `Spec.build`: when set, the image is built locally via `Docker.build_image/5`; otherwise it is pulled from a registry via `Docker.pull_image/3`.

### Key modules

- `Dockd` — the entire public API in one module. `apply/2`, `apply_package/2`, `install_packages/2`, `list_packages/1`, `list/1`, `get/2`, `destroy/2`, `start/2`, `stop/2`, `restart/2`, `running?/2`, `logs/2`, `inspect/2`, `refresh/2`, `shell_command/3`, `open_shell/2`, `shell_send/3`, `close_shell/2`, `copy_to/3`, `list_temp_files/1`, `delete_temp_files/1`, `info/1`, `option_keys/0`. `install_packages/2` dispatches on the reference: an existing local directory installs from disk, anything else is cloned as a git URL
- `Dockd.Spec` — declarative request type; `from_opts/2`, `from_attrs/1`, `option_keys/0`, `prefix_name/1`, `short_name/1`
- `Dockd.Spec.Parser` / `.Interpolator` / `.Normalizer` — the JSON-package pipeline: read+parse, `${VAR}` substitution, then attribute normalization
- `Dockd.Instance` — view type; `from_inspect/1`, `managed_labels/1`, `short_name/1`
- `Dockd.Provisioner` — the create-an-Instance pipeline
- `Dockd.Packages` — package storage: reference resolution, listing, install from git or a local path
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

Pure unit tests (no Docker daemon required): `test/dockd/spec_test.exs`, `test/dockd/instance_test.exs`, `test/dockd/spec/*_test.exs`, `test/dockd/shell_arg_test.exs`, `test/dockd/shell_test.exs`, `test/dockd/ssh_test.exs`, `test/dockd/ssh/*_test.exs`, `test/dockd/open_shell_script_test.exs`.

Integration tests requiring a running Docker daemon: `test/dockd_test.exs`, `test/dockd/env_test.exs`, `test/dockd/packages_test.exs`. They use `busybox:1.37.0` as the test image. With no daemon reachable these fail with `:endpoint_not_resolved`.

Test fixtures (e.g. a minimal Dockerfile) live in `test/fixtures/`.
