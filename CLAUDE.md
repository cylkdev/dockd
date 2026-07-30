# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
mix compile              # Compile
mix test                 # Run all tests (integration tests require a running Docker daemon)
mix test path/to/test.exs          # Run a single test file
mix test path/to/test.exs:42       # Run a single test by line number
mix format               # Format code
mix dialyzer             # Must stay at 0 errors
```

## Architecture

Dockd is a plain Elixir library that manages local Docker containers ("instances") as named workspaces. It depends on one sibling library: `docker` at `../docker`, which wraps the Docker Engine API over HTTP via a Unix socket. The `elixir_exec` dependency is gone — see "Running OS processes".

### Nine modules, one job

The library does one thing: **turn a declarative description of a container into a live, labelled Docker container you can run commands in, and tear it down.** Everything that was not needed for that has been removed. `lib/` is 9 modules and the public API is 19 functions.

Things that are deliberately **not** here, and should not come back without a reason:

- a package manager (install-from-git, scaffolding, listing, deletion, name-to-path resolution)
- `${VAR}` interpolation
- host-side `git clone` (`:repos`)
- an SSH / remote-daemon bridge
- a terminal-window launcher
- a `priv/` directory of any kind

### Stateless, Docker-as-source-of-truth

Dockd holds no state of any kind. There is no application module, no supervision tree (`mix.exs` has no `mod:` key), no GenServers, no ETS tables, no local stores, and nothing derived is cached. Every container created via `Dockd.apply/6` carries two labels that make it self-describing:

- `org.dockd.instance` = `"true"` — discovery marker
- `org.dockd.instance.name` = `<instance_name>` — human-readable name

After a crash or restart, `Dockd.list/2` rediscovers every managed instance by filtering Docker on the marker label, and `Dockd.get/3` fetches a single instance by name. The `%Dockd.Instance{}` struct is a view of the live container — hydrated on demand from `docker inspect`, never long-lived.

Every read goes to the live daemon. Nothing dockd writes is later trusted as a cache.

### Type separation

| Module | Role |
|---|---|
| `Dockd.Spec` | Declarative request. Pure input — consumed by `apply/6`, then discarded. |
| `Dockd.Instance` | View of an existing container. Hydrated from `find_container/2`. |
| `Dockd.ApplyResult` | One call's outcome: `%{instance, step_results}`. |

Caller-runtime context never touches a struct or a container label. The required parts (`endpoint`, `disk_mount_enabled`, `host_env`, `temp_root`) are positional arguments; the optional parts (`:api_version`, `:platform`, `:networks`, `:network_mode`, `:container_staging_root`) are per-call `opts`. See "No configuration" below.

### Packages are data, not machinery

A package used to be five modules (`Packages`, `Spec.Parser`, `Spec.Interpolator`, `Spec.Normalizer`, `Spec.Encoder`, ~1,230 lines) implementing a package manager. It is now **one function**: `Dockd.Spec.from_map/1`.

A package is a plain, **atom-keyed** map. The caller loads it, interpolates any variables, and absolutizes any paths — then hands the map over. Dockd does none of that on their behalf, which is why:

- **There is no file I/O in the spec path.** No packages root, no `resolve_path`, no file-suffix rule. Dockd never learns where the map came from, so the docs describe a package as a map and name no serialization format.
- **There is no `${VAR}` substitution.** What is in the map is what reaches Docker.
- **Relative `:build` paths are rejected** rather than resolved. There is no package directory to resolve against, so a relative path would silently fall back to the calling process's CWD. `Spec.validate/1` already enforced this; removing the normalizer simply made it the only rule.

If a feature request starts with "dockd should find/resolve/download/generate a package", the answer is that the caller does that in three lines of their own code.

### Input keys are atoms

**Every key dockd is given is an atom** — the spec map and every nested `:build`, `:steps`, `:copy` and `:mounts` entry. A string key is not a second accepted spelling; `from_map/1` rejects it, and the error names the cause (`atom_key_hint/1`) rather than listing every field as an unknown key. Reads are plain `Map.get/2`.

`Dockd.Spec.fetch_either/2` — the atom-or-string reader — is deleted, along with `Provisioner.get_value/2` and `atomize_mount_keys/1`, which called `String.to_atom/1` on caller data. Do not reintroduce a dual-key read: it doubles the shape of every nested map and puts the ambiguity in dockd instead of in the one caller who knows the map's source.

A string key is legitimate in exactly two places:

- **Docker's own response shapes** — `"Id"`, `"Name"`, `"Labels"`, `"Config"`, and the pull/build stream events (`"status"`, `"stream"`, `"errorDetail"`). These are matched, not constructed.
- **Payload whose keys are arbitrary names** — `Spec.labels` and `host_env`. `"org.dockd.instance"` and `"GITHUB_TOKEN"` are not atoms without quoting, and atomizing caller data to reach a Docker label would mint atoms for nothing.

Where `Map.get/2` feeds a `case`, `nil` gets its own clause and a wrong *type* gets another. An absent key and a key holding a number are different failures, and `_ ->` reports them as the same one.

### Two constructors, one validator

- `Spec.new(image, instance_name, opts)` and `Spec.from_map(map)` are the only constructors. Both end in `validate/1`, so a map-sourced and an Elixir-native spec are held to identical rules.
- `Spec.validate/1` is the only checker **of the fields it covers** — `:image`, `:instance_name`, `:labels`, and `:build` path absoluteness. Both constructors call it, and `Provisioner.run/6` calls it again as the first pipeline stage: `@enforce_keys [:image, :instance_name]` blocks an incomplete literal, but not an explicit `nil`.
- `from_map/1` owns exactly one check the others do not: **unknown keys**. A typo that is silently ignored does nothing and says nothing, so it is rejected at the boundary and the message names both the offending keys and the valid set. `validate_map_keys/1` tests membership with `in` and renders with `inspect/1`, so a key that is not an atom at all still produces a tagged error instead of raising.
- The remaining collection fields — `:env`, `:mounts`, `:steps`, `:copy` — are **not** validated by `Spec.validate/1`. Each is checked exactly once, by its `Provisioner` normalizer (`resolve_env/2`, `normalize_mounts/1`, `normalize_step_specs/1`, `normalize_copy_specs/1`). That split is deliberate: the normalizers need to *transform* those fields anyway, so validating them in a second place would mean two passes over the same data.
- **One question, one implementation.** `Dockd.HostTool` owns the two repeated host-path questions (is this a usable staging root, is this safe to `rm_rf`). Both are preflight checks on caller-supplied arguments, so both report `:validate` — a relative `temp_root` is a bad argument, not a failed copy.
- **No public function raises on data it validates.** Every invariant listed by `validate/1` and by `Provisioner.run/6`'s pipeline phases is reported as `{:ok, _} | {:error, %ErrorMessage{}}`; an `ArgumentError` or `FunctionClauseError` in place of one of those errors is a bug, not API. This is *not* a promise that any term at all is accepted: the `Dockd` functions carry no argument-type guards, so passing something that is not a keyword list as `opts` raises from `Keyword`. The typed error is the contract for wrong *values*, not for wrong *types*.

### Clauses that look redundant but are not

These have each been deleted once already — leave them alone:

- **`Provisioner.expand_env(%{spec: %Spec{env: []}})`** — reads as a pointless fast path. Remove it and `expand_env/1`'s only return narrows `spec.env` to the resolved `[binary()]`, after which dialyzer reads `normalize_mounts/1`'s catch-all — the sole `":mounts must be a list"` validator — as unreachable and `mix dialyzer` fails. The declared `Spec.t()` is optimistic; a hand-built struct can violate it at runtime.
- **`Provisioner.rename_key/3` and `rename_keyword/3`'s `{nil, m} -> m` arms** — these are the *absent-key* path, not a nil-hedge. `Map.pop/2` returns `{nil, map}` when the key is missing, so removing the arm would write `version: nil` into every Docker call.

### `:env` has exactly two shapes

`"NAME=value"` (literal) or `"NAME"` (read from `host_env`; absent is a `:validate` error). That is the whole rule.

There used to be five shapes — a `{name, opts}` tuple carrying `:value`, `:default`, or `:optional` — with a precedence rule stating that an explicit `:default` outranked `host_env`. All of it is gone, along with `resolve_host_env/3` and `resolve_from_host_env/3`. `@type env_entry` is now just `binary()`.

Practical consequence: there is one shape to document and nothing to translate between.

### Naming: two distinct "name" fields

| Key | Where | Means |
|---|---|---|
| `instance_name` | top level of a spec map / `Spec` field / positional arg of `apply_image/7` | The user-facing short name. `Spec.prefix_name/1` derives the container name `dockd-<value>` at the Docker boundary |
| `step_name` | inside a `steps` entry | Display name for one setup step; appears in `:setup` errors and on `StepResult` |

`Spec.instance_name` stores the **short** name, and `prefix_name/1` is the one place the `dockd-` prefix is added. `validate/1` rejects a name that already carries the prefix, since `"foo"` and `"dockd-foo"` would otherwise name the same container.

`%Dockd.Instance{}` keeps a plain `:name` field: it is a different struct and `instance.name` is already unambiguous.

The old `"name"` (top level) and `"label"` (step) keys were renamed. `from_map/1`'s unknown-key check rejects both, along with the retired `"repos"`.

### Provisioning pipeline

`Dockd.Provisioner.run/6` takes `(spec, endpoint, disk_mount_enabled, host_env, temp_root, opts)` and runs a sequential pipeline: **validate spec** -> **enforce disk-mount policy** -> **expand env** -> **normalize mounts** -> **validate source** -> **normalize steps/copies** -> **build or pull image** -> **create container** -> **start container** -> **copy host files** -> **run setup steps** -> **hydrate Instance**. Each phase is tagged at `details.phase` (`:validate`, `:build`, `:pull`, `:create`, `:start`, `:copy`, `:setup`, `:discover`) so errors report where the failure occurred. When a container was created before the failure, `details.instance` carries a hydrated `Dockd.Instance` (and `details.step_results` whatever was captured) so the caller can clean up with `Dockd.destroy/3`.

`enforce_disk_mount_policy/2` has clauses for `true` and `false` only — deliberately no `nil` clause, because an absent policy must never read as permission to expose the host.

`Provisioner.resolve_env/2` is public: it is the same env resolution the pipeline runs, exposed so the rules are checkable without a daemon.

Outside the pipeline, `:lifecycle` (`start/3`/`stop/3`) and `:destroy` are also used.

The image source is determined by `Spec.build`: when set, the image is built locally via `Docker.build_image/5`; otherwise it is pulled from a registry via `Docker.pull_image/3`.

### Errors: `ErrorMessage`, built inline

**There is no dockd error module, and there must not be one.** `Dockd.Error` was deleted; so was a short-lived `Dockd.Failure` constructor. Every failure returns `{:error, %ErrorMessage{}}` from the [`error_message`](https://hex.pm/packages/error_message) package, and **every one is built inline at the site it occurs**:

```elixir
{:error, ErrorMessage.bad_request(":mounts must be a list", %{phase: :validate})}
```

Yes, the `:validate` literal appears ~20 times in `Provisioner`. That is the point: what a failure reports is visible where it happens, rather than assembled behind a helper whose table you have to go read. Do not "tidy this up" by reintroducing `validate_error/1` or an error module — it has been removed twice.

Every public function returns `:ok` or `{:ok, term()}` on success and `{:error, %ErrorMessage{}}` on failure. **No exceptions**: `shell_command/4`, `logs/3` and `open_shell/3` used to leak `Docker.result(...)` and now wrap it, and `shell_send/3` used to return `{:error, {reason, handle}}` and now carries the handle at `details.shell`.

`code` classifies the failure, `details.phase` locates it. Both exist because they are not one-to-one:

| phase | constructor |
|---|---|
| `:validate` | `ErrorMessage.bad_request/2` |
| `:build`, `:setup`, `:copy` | `ErrorMessage.unprocessable_entity/2` |
| `:pull`, `:create`, `:start`, `:lifecycle`, `:destroy` | `ErrorMessage.bad_gateway/2` |
| `:discover` | `ErrorMessage.not_found/2` |

`code` is chosen from **the phase, never from Docker's HTTP status**. The status Docker actually returned is kept verbatim at `details.reason` instead, so it can be matched on rather than parsed back out of a message. Messages are plain human text with no `status=`/`body=` suffix appended — `ErrorMessage.to_string/1` renders `details` underneath the message, so nothing is lost to a human reading a log.

`details` keys, all omitted when there is nothing to report rather than set to `nil`:

| key | when | why it must survive |
|---|---|---|
| `:phase` | always | locates the failure in the pipeline |
| `:instance` | after a container exists | **the cleanup path** — the caller passes it to `Dockd.destroy/3`; losing it leaks containers |
| `:step_results` | `:setup` | output from steps that ran before the failure |
| `:exit_code`, `:output` | `:setup` | the failing step's status and captured output |
| `:reason` | Docker-originated | Docker's raw reason, unmodified |
| `:shell` | `shell_send/3` | the terminal handle, so the session can still be closed |

`details.instance` is the one with teeth: `test/dockd_test.exs` asserts a failed setup step yields an instance that `destroy/3` actually removes. Without it a failed apply leaves a container running.

### Running OS processes

**Dockd runs none.** There is no `System.cmd/3`, no `Port.open/2`, and no `ElixirExec` — the dependency was dropped along with the last shell-out.

That shell-out was `Files.tar_batch/4`, which ran the host's `tar` to build the upload archive. It is now `Files.build_archive/1` on OTP's `:erl_tar`, which was verified to preserve everything a copy needs: recursive directories, empty directories, symlinks, permission bits, and names past the 100-byte ustar limit. `test/dockd_test.exs` has an integration test (`"copies a directory tree, preserving nesting, empty dirs, links and modes"`) covering exactly those shapes against a real daemon.

Three things disappeared with it, and none should come back:

- **`:tar_path` / `:tar_env` / `:tar_extra_args`** — `:erl_tar` writes no xattrs, ACLs or macOS metadata to begin with, so the BSD/GNU flag divergence that `:tar_extra_args` existed to paper over is not a question any more.
- **`Provisioner.validate_tools/1` and `require_tool/5`** — a whole pipeline phase whose job was "this spec has `:copy`, did the caller pass a `tar`?".
- **`HostTool.executable/3` and `HostTool.env/2`** — nothing left to locate or hand an environment to.

If a change needs an external program, that is the moment to ask whether OTP already ships it. The stdout/stderr separation that `ElixirExec.capture/2` was chosen for mattered *only* because stdout was the archive bytes; with no child process there are no streams to keep apart.

### Key modules

- `Dockd` — the entire public API in one module. `apply/6`, `apply_image/7`, `list/2`, `get/3`, `destroy/3`, `start/3`, `stop/3`, `restart/3`, `running?/3`, `logs/3`, `inspect/3`, `refresh/3`, `shell_command/4`, `open_shell/3`, `shell_send/3`, `close_shell/2`, `copy_to/5`, `list_temp_files/1`, `delete_temp_files/1`
- `Dockd.Spec` — declarative request type; `new/3` and `from_map/1` (the two constructors), `validate/1` (the only checker), `option_keys/0`, `prefix_name/1`, `short_name/1`
- `Dockd.Instance` — view type; `marker_label/0`, `name_label/0`, `managed_labels/1`, `from_inspect/1`, `short_name/1`
- `Dockd.Provisioner` — the create-an-Instance pipeline; also `destroy/3`, `docker_options_from/2` (the single place `endpoint` is validated), `resolve_env/2`
- `Dockd.ApplyResult` — `%{instance, step_results}` returned by `apply/6`. `@enforce_keys [:instance]`: a result without one describes nothing, and a *failed* apply carries its partial instance at `details.instance` on the `%ErrorMessage{}` instead
- `Dockd.HostTool` — `@moduledoc false`. The one home for `staging_root/2` and `sweepable_root/2`. Returns `:ok | {:error, %ErrorMessage{}}` tagged `:validate`, so callers pass it straight through
- `Dockd.Files` — tars host files/dirs in-process with `:erl_tar` and uploads via `Docker.put_archive/4`; also owns staging-dir housekeeping under a caller-supplied `temp_root`. The archive is written inside the per-call tempdir the `after` block already removes, and closed before it is read — `:erl_tar` writes the trailer on `close/1`
- `Dockd.StepResult` — captured output and exit code from a single setup step. `@enforce_keys [:step_name, :cmd, :output]` enforces the first three documented data invariants instead of only asserting them in a comment. `:exit_code` is deliberately *not* enforced — `nil` is a real value, meaning Docker reported no status

### No configuration

There is none, deliberately. Dockd reads no environment variable, no application config, no home directory, no CWD, no `System.tmp_dir!()`, no `:os.type()`, and no `PATH`. Every input a function needs arrives as an argument: required ones are positional, genuinely optional ones live in a trailing `opts \\ []` with a **literal** default (never one that reads process state).

Four runtime inputs recur across the public API, none with a default:

| Argument | Was read from | Why it must be explicit |
|---|---|---|
| `endpoint` | `DOCKER_HOST` (in `../docker`) | Decides *which daemon a container is created on* |
| `disk_mount_enabled` | absent meant `true` | Gates host mounts, file copies, host env — must fail **closed** |
| `host_env` | `System.get_env/0` | A spec can only reach values the caller handed it; `%{}` reaches nothing |
| `temp_root` | `System.tmp_dir!()` | `delete_temp_files/1` deletes recursively; the target must be named |

`:container_staging_root` stays in `opts` because it is genuinely optional (it defaults to `"/tmp"`, a container path, not a host one). There is no host tooling to pass: nothing is looked up on `PATH` because nothing is executed.

There is no option allowlist. `apply/6` reads the keys it knows and ignores the rest, as any keyword-option API does. The property that matters is enforced structurally rather than by a rejection list: `endpoint`, `disk_mount_enabled`, `host_env` and `temp_root` are *positional*, so a caller who passes the old `socket:` or `packages_path:` option has still had to supply the positional value, and no ambient default exists for the ignored key to revert to.

**Acceptance checks.** Two, and both must stay green:

1. `test/dockd/no_ambient_input_test.exs` — sets `DOCKER_HOST` and the retired packages-root env/config to garbage, then drives the spec-to-container path purely from arguments. It is the regression test for this whole property, because "the absence of a read" cannot be unit-tested on any single function. One of its cases asserts that **no public function name matches `package|from_file|load`** — the strongest form the guarantee can take, since the read cannot happen if the code that would do it does not exist.
2. This grep, which must return **zero hits in executable code** — no exemptions there, because deleting `priv/` removed both `:code.priv_dir/1` reads:

```sh
grep -rnE 'System\.(get_env|fetch_env|user_home|tmp_dir)|Application\.(get|fetch)_env|File\.cwd|code\.priv_dir|:os\.type|System\.(cmd|find_executable)\("' lib/
```

It does not currently print nothing, and that is expected: it matches prose as readily as code, and the property is worth *documenting* as well as holding. Every hit today is a doc example or a comment — five in `lib/dockd.ex` (four `@doc` examples passing `System.tmp_dir!()` as `temp_root`, which is exactly the caller-supplies-it pattern, plus the sentence saying `host_env` is never `System.get_env/0`) and two in `lib/dockd/files.ex` (comments explaining that archive flags do *not* come from `:os.type()`). Diff any new hit against that list: one on a line that runs is a bug.

`System.cmd` is in the grep because it is ambient (a PATH lookup) *and* because dockd runs no external process at all.

### Docker dependency

The `Docker` module (at `../docker`) provides the low-level API calls. Key functions used by dockd: `pull_image/3`, `build_image/5`, `create_container/4`, `start_container/2`, `stop_container/2`, `delete_container/3`, `put_archive/4`, `list_containers/2`, `find_container/2`, `container_logs/3`, `container_running?/2`, and the `Docker.Terminal` family (`run_with_status/3`, `open/2`, `command/3`, `close/1`).

### Testing

Pure unit tests (no Docker daemon required): `test/dockd/spec_test.exs`, `test/dockd/instance_test.exs`, `test/dockd/apply_opts_test.exs`, `test/dockd/env_test.exs`, `test/dockd/no_ambient_input_test.exs`.

`test/dockd/env_test.exs` is pure *because* `host_env` is an argument — it does not need `System.put_env/2` to set up a case, so it is `async: true`.

`test/dockd/spec_test.exs` owns the `from_map/1` contract, including the cases the deleted parser and normalizer tests used to cover: unknown keys rejected, string keys rejected with the reason named, retired keys (`:name`, `:repos`, `:label`) rejected, relative `:build` paths rejected, and — per the no-raise rule — a non-map argument and a non-atom map key both reported as tagged errors rather than raising.

`test/dockd_test.exs` needs a running daemon for most of its tests. Its helpers at the bottom of the file are where the suite decides what to pass for `endpoint`, `temp_root` and `host_env` — a test *may* discover these from the environment; the library may not. Its `Spec.from_map/1 end to end` block is the one that proves the data-driven path works against a real daemon: a map with `:env` and `:steps`, a map carrying user `:labels`, and a map that builds its own image from an absolute `:dockerfile`.

Integration tests requiring a running Docker daemon use `busybox:1.37.0` as the test image. With no daemon reachable they fail with `:endpoint_not_resolved`.

Test fixtures (a minimal Dockerfile and one taking build args) live in `test/fixtures/`.
