# Standalone `dockd` CLI — Design

**Date:** 2026-07-02
**Status:** Approved for planning
**Scope:** Ship `dockd_cli` as a self-contained command-line binary that an end user can run on macOS or Linux without installing Elixir, Erlang, or knowing anything about the BEAM.

## Goal

Produce a single self-contained executable named `dockd` that mirrors the existing `mix dockd.*` command surface. The end user downloads one file, puts it on their `PATH`, and runs `dockd ...`. The only runtime prerequisite is a running Docker daemon (which dockd already requires).

## Non-goals (deferred to follow-up specs)

- CI / GitHub Actions release build matrix.
- Distribution channels (GitHub Releases, install script, Homebrew tap).
- macOS code signing / notarization.
- Windows support (macOS + Linux only).
- Folding the `dockd_tui` interactive shell into the CLI (`dockd shell <instance>`).

This spec covers the **code refactor** and a **local Burrito build** that produces a working self-contained binary on the developer's machine.

## Decisions

| Question | Decision |
|---|---|
| Target OS | macOS + Linux (no Windows) |
| Runtime | Fully bundled — ERTS baked in, nothing to install |
| Packaging tool | Burrito (Mix release + Zig cross-compile, single-file executable) |
| Command surface | Mirror all existing Mix tasks 1:1 |
| Dispatch architecture | Extract command logic into plain modules; route with the Optimus CLI library |
| Distribution | Local build only for now; CI + channels deferred |

## Architecture

Introduce a command layer inside `apps/dockd_cli` that is fully decoupled from Mix. The logic that currently lives inside `Mix.Tasks.Dockd.*` modules moves into plain modules; the Mix tasks and the new binary entrypoint both become thin wrappers over that shared layer.

```
apps/dockd_cli/
  lib/
    dockd_cli/
      main.ex              # Burrito/escript entrypoint: main(argv)
      cli.ex               # Optimus spec: groups, subcommands, flags, help, version
      output.ex            # stdout/stderr/table/error helpers (replaces Mix.shell())
      options.ex           # global option + env resolution -> per-call opts keyword list
      commands/
        instance/
          list.ex
          run.ex
          stop.ex
          start.ex
          restart.ex
          destroy.ex
          logs.ex
          inspect.ex
        package/
          install.ex
          show.ex
          validate.ex
        info.ex
        ssh/               # existing ssh-related tasks, same treatment
    mix/tasks/dockd*.ex    # KEPT — refactored to thin wrappers calling commands/*
```

### Command layer contract

Each `DockdCli.Commands.*` module exposes a plain function of the shape:

```elixir
@spec run(map(), keyword()) :: :ok | {:error, term()}
def run(parsed_args, opts)
```

- `parsed_args` — the flags/positionals already parsed by Optimus (or by a Mix task wrapper).
- `opts` — the per-call options keyword list (`:socket`, `:host`, `:api_version`, `:platform`, etc.) that the `Dockd.*` public API already accepts.
- Output goes through `DockdCli.Output` (never `Mix.shell()` / `Mix.raise`).
- Return `:ok` or `{:error, reason}`; the entrypoint maps that to a process exit code.

This keeps the command layer testable with no Mix and (for non-integration cases) no Docker daemon.

### Entry points

- **Binary:** `DockdCli.Main.main(argv)` parses with `DockdCli.CLI` (Optimus), resolves global options/env into `opts`, dispatches to the matching command module, and calls `System.halt/1` with `0` on `:ok` or non-zero on `{:error, _}`.
- **Mix tasks:** each `Mix.Tasks.Dockd.*` keeps its `run/1`, calls `Mix.Task.run("app.start")`, parses (or forwards) args, and delegates to the same command module. Behavior parity between `mix dockd.*` and `dockd ...` is guaranteed because they share one implementation.

## CLI surface (Optimus)

Single binary `dockd`, nested subcommands mirroring today's tasks:

- `dockd instance list`
- `dockd instance run` — flags: `--image`, `--dockerfile`, `--tag`, `--package`, `--preset`, `--name`, `--short`, `--detached` (unchanged from today's `dockd.instance.run`)
- `dockd instance stop|start|restart|destroy <name>`
- `dockd instance logs <name>` (with today's log filter flags)
- `dockd instance inspect <name>`
- `dockd package install|show|validate ...`
- `dockd info`
- `dockd ssh ...` (existing ssh tasks)

Optimus provides `dockd --help`, `dockd instance --help`, per-command flag validation, and `dockd --version`.

## Runtime configuration

Today's config is compile-time (`config/config.exs` sets only `temp_dir` and RPC settings), and the CLI tasks don't pass a Docker socket — they rely on the `docker` library default. A shipped binary must be configurable by the end user at runtime.

- **Docker connection:** honor `DOCKER_HOST` and/or `DOCKER_SOCKET` environment variables plus global `--socket` / `--host` flags. `DockdCli.Options` resolves these (flag overrides env overrides default) into the `opts` keyword list threaded into every `Dockd.*` call.
- **Temp dir:** overridable via `DOCKD_TMP`, with a sane per-OS default; do not hard-bake `/tmp/dockd` into the release.
- **Boot-time config:** use `config/runtime.exs` for anything that must resolve when the release boots, since `config/config.exs` values are frozen at build time.

## The `run` command

Behavior is kept at parity with today's `dockd.instance.run`:

1. Resolve source (`--image` / `--dockerfile` / `--package` / `--preset`), validating mutually exclusive flags.
2. Provision via `Dockd.apply/2` or `Dockd.apply_package/2`.
3. Print the `docker exec -it <name> <shell>` connect command.
4. Block on `IO.gets/1`; on Enter, `Dockd.destroy/1` and exit.
5. `--short` silences banners; `--detached` prints connect + cleanup hints and returns without waiting.

This relies only on `IO.gets` / `IO.write`, which work unchanged inside a Burrito release. No behavior change.

## Packaging & build (Burrito)

- Add `burrito` as a dependency of `apps/dockd_cli` and define a Mix release for the CLI with the CLI `main_module` wired to `DockdCli.Main`.
- Burrito wraps a standard Mix release, bundling ERTS, and uses **Zig** to cross-compile/produce self-contained single-file executables per target.
- Targets for local build: `macos-aarch64` (primary dev target) and `linux-x86_64`; `macos-x86_64` / `linux-aarch64` configured but optional.
- **Dev-machine prerequisite:** Zig must be installed to build. Documented in the repo README. End users need nothing but the produced binary and a running Docker daemon.
- The `docker` GitHub dependency compiles into the release normally; no special handling expected.

## Testing

- **Command modules:** unit-tested directly — construct parsed args, invoke `run/2`, assert on captured output via `ExUnit.CaptureIO`. No Mix, and no daemon for pure cases.
- **Existing tests:** keep the current Mix-task and integration tests (busybox against a real daemon) working through the thin-wrapper tasks.
- **Build smoke test:** a documented manual/local check that builds the Burrito binary and runs `dockd --help` and `dockd instance list` against a live daemon. (Automated CI smoke test deferred with CI.)

## Risks / open considerations

- **Zig toolchain friction** on the dev machine is the most likely snag; document the exact install step.
- **Optimus flag mapping:** a few existing tasks have bespoke flag validation (e.g. `run`'s mutually-exclusive sources); that validation stays in the command module rather than relying solely on Optimus.
- **Config that was compile-time** must be audited for anything that would wrongly freeze into the release; move genuinely-runtime values to `runtime.exs`.
- **macOS Gatekeeper:** unsigned local binaries run fine for the builder; signing/notarization only matters once distributed (deferred).

## Rollout

1. Extract command layer; refactor Mix tasks to thin wrappers (behavior unchanged, tests green).
2. Add Optimus CLI spec + `DockdCli.Main` entrypoint.
3. Add runtime config resolution (`DockdCli.Options`, `runtime.exs`, env vars).
4. Add Burrito release config; produce a local self-contained `dockd` binary.
5. Manual smoke test against a live Docker daemon.

Follow-up specs: CI release matrix, distribution (GitHub Releases + install script / Homebrew), optional `dockd shell` TUI integration.
