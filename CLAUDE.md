# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
mix compile              # Compile
mix test                 # Run all tests (integration tests require a running Docker daemon)
mix test path/to/test.exs          # Run a single test file
mix test path/to/test.exs:42       # Run a single test by line number
mix format               # Format code
mix dockd <subcommand>   # Forward to the dockd CLI (e.g. `mix dockd instance list`)
```

## Architecture

Dockd is an Elixir OTP application that manages local Docker containers ("instances") as named workspaces. It depends on a sibling `docker` library at `../docker` which wraps the Docker Engine API over HTTP via a Unix socket.

### Stateless, Docker-as-source-of-truth

Dockd holds no in-process state. `Dockd.Application` starts an empty supervisor; there are no GenServers, ETS tables, or local stores. Every container created via `Dockd.apply/2` carries two labels that make it self-describing:

- `org.dockd.instance` = `"true"` — discovery marker
- `org.dockd.instance.name` = `<workspace_name>` — human-readable name

After a crash or restart, `Dockd.list/1` rediscovers every managed instance by filtering Docker on the marker label, and `Dockd.get/2` fetches a single instance by name. The `%Dockd.Instance{}` struct is a view of the live container — hydrated on demand from `docker inspect`, never long-lived.

### Type separation

| Module | Role |
|---|---|
| `Dockd.Spec` | Declarative request. Pure input — consumed by `apply/2`, then discarded. |
| `Dockd.Instance` | View of an existing container. Hydrated from `find_container/2`. |
| `Dockd.ApplyResult` | One call's outcome: `%{instance, step_results}`. |

Caller-runtime context — Docker daemon connection (`:socket`, `:host`, `:platform`, …) and the policy flag `:disk_mount_enabled` — lives in per-call `opts`. It never touches a struct or a container label.

### Provisioning pipeline

`Dockd.Provisioner.run/2` takes a `Spec` plus per-call `opts` and runs a sequential pipeline: **enforce disk-mount policy** -> **expand env** -> **normalize mounts** -> **validate source** -> **normalize steps/repos/copies** -> **build or pull image** -> **create container** -> **start container** -> **fetch repos** -> **copy host files** -> **run setup steps** -> **hydrate Instance**. Each phase is tagged (`:validate`, `:build`, `:pull`, `:create`, `:start`, `:fetch`, `:copy`, `:setup`, `:discover`) so errors report where the failure occurred. When a container was created before the failure, the error carries a hydrated `Dockd.Instance` (and any captured `step_results`) so the caller can clean up with `Dockd.destroy/1`.

The image source is determined by `Spec.build`: when set, the image is built locally via `Docker.build_image/5`; otherwise it is pulled from a registry via `Docker.pull_image/3`.

### Key modules

- `Dockd` — public API: `apply/2`, `apply_package/2`, `list/1`, `get/2`, `destroy/2`, `shell_command/3`, `open_shell/2`, `shell_send/3`, `close_shell/1`
- `Dockd.Spec` — declarative request type; `from_opts/2`, `from_json/1`, `from_json_file/1`
- `Dockd.Instance` — view type; `from_inspect/1`, `managed_labels/1`, `short_name/1`
- `Dockd.Provisioner` — the create-an-Instance pipeline
- `Dockd.ApplyResult` — `%{instance, step_results}` returned by `apply/2`
- `Dockd.Git` — clones git repos on the host and uploads via `Docker.put_archive/4`
- `Dockd.FileCopy` — tars host files/dirs and uploads via `Docker.put_archive/4`
- `Dockd.Error` — phase-tagged error struct with optional `:instance` and `:step_results`
- `Dockd.StepResult` — captured output and exit code from a single setup step
- `Mix.Tasks.Dockd` — single forwarder entry point (`mix dockd <subcommand>`), dispatching to `DockdCli.CLI.run/1`

### Docker dependency

The `Docker` module (at `../docker`) provides the low-level API calls. Key functions used by dockd: `pull_image/3`, `build_image/5`, `create_container/4`, `start_container/2`, `stop_container/2`, `delete_container/3`, `exec_run_with_status/3`, `put_archive/4`, `list_containers/2`, `find_container/2`.

### Testing

`test/dockd/spec_test.exs` and `test/dockd/instance_test.exs` are pure unit tests (no Docker daemon required). `test/dockd_test.exs` and `test/dockd/env_test.exs` are integration tests that require a running Docker daemon; they use `busybox:1.37.0` as the test image. Test fixtures (e.g., a minimal Dockerfile) live in `test/fixtures/`. Mix task tests use `Mix.Shell.Process` and `ExUnit.CaptureIO` to capture output and provide stdin input.
