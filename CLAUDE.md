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

Caller-runtime context never touches a struct or a container label. The required parts (`endpoint`, `disk_mount_enabled`, `host_env`, `temp_root`) are positional arguments; the optional parts (`:api_version`, `:platform`, `:networks`, `:network_mode`, host tooling) are per-call `opts`. See "No configuration" below.

### One constructor, one validator

`%Dockd.Spec{}` has a single construction path, because it used to have three that validated differently: `from_opts/2` raised `ArgumentError`, `from_attrs/1` checked only `:image`, and a struct literal checked nothing — after which four other places re-checked the same invariant with three different failure shapes.

Now:

- `Spec.new(image, instance_name, opts)` is the only constructor. `Spec.from_attrs/1` is a thin adapter onto it, so package-sourced and Elixir-native specs share one validation body.
- `Spec.validate/1` is the only checker **of the fields it covers** — `:image`, `:instance_name`, `:labels`, and `:build` path absoluteness. `new/3` calls it, and `Provisioner.run/6` calls it again as the first pipeline stage — `@enforce_keys [:image, :instance_name]` blocks an incomplete literal, but not an explicit `nil`. `Spec.validate_instance_name/1` is public (`@doc false`) for exactly one reason: `Spec.Encoder` gates a *scaffolded* package on the same name rules a *loaded* one is held to. It used to keep its own copy of the pattern, and that copy omitted the `dockd-` prefix rejection, so the scaffolder wrote packages that failed at apply time.
- The remaining collection fields — `:env`, `:mounts`, `:steps`, `:repos`, `:copy` — are **not** validated by `Spec.validate/1`. Each is checked exactly once, by its `Provisioner` normalizer (`resolve_env/2`, `normalize_mounts/1`, `normalize_step_specs/1`, `normalize_repo_specs/1`, `normalize_copy_specs/1`). That split is deliberate: the normalizers need to *transform* those fields anyway, so validating them in a second place would mean two passes over the same data.
- **One question, one implementation.** `Dockd.HostTool` owns the three repeated host-path questions (is this an executable, is this a usable staging root, is this safe to `rm_rf`). It returns a bare message, not a `%Dockd.Error{}`, so each caller attaches its own phase — which is also what lets `Dockd.Ssh`, whose contract is `{:error, binary()}`, share the same rules. `Dockd.Spec.fetch_either/2` is the single atom-or-string key read; it uses `Map.fetch/2` rather than `||` so a legitimate `false` is not mistaken for an absent key.
- `Dockd.Spec.Parser` checks JSON *shape* only. Presence and usability of `"image"` / `"instance_name"` are semantic, so they belong to `validate/1`; `Dockd.load_package_spec/3` prefixes the file path onto the message at the boundary.
- **No public function raises on data it validates.** Every invariant listed by `validate/1` and by `Provisioner.run/6`'s pipeline phases is reported as `{:ok, _} | {:error, %Dockd.Error{}}` with a phase tag; an `ArgumentError` or `FunctionClauseError` in place of one of those errors is a bug, not API. This is *not* a promise that any term at all is accepted: the `Dockd` functions carry no argument-type guards, so passing something that is not a keyword list as `opts` raises from `Keyword`. The typed error is the contract for wrong *values*, not for wrong *types*.

### Clauses that look redundant but are not

The codebase has been swept for duplicated and unreachable checking. These four survived on purpose and have each been deleted once already — leave them alone:

- **`Provisioner.expand_env(%{spec: %Spec{env: []}})`** — reads as a pointless fast path. Remove it and `expand_env/1`'s only return narrows `spec.env` to the resolved `[binary()]`, after which dialyzer reads `normalize_mounts/1`'s catch-all — the sole `":mounts must be a list"` validator — as unreachable and `mix dialyzer` fails. The declared `Spec.t()` is optimistic; a hand-built struct can violate it at runtime.
- **`Provisioner.rename_key/3` and `rename_keyword/3`'s `{nil, m} -> m` arms** — these are the *absent-key* path, not a nil-hedge. `Map.pop/2` returns `{nil, map}` when the key is missing, so removing the arm would write `version: nil` into every Docker call.
- **`Normalizer.maybe_put_opt(opts, _key, nil)`** — also the absent-key path. An explicit JSON `null` is already rejected by `check_env_entry_types/2`, so this clause only fires for a key that isn't there. Removing it emits `value: nil` into every env tuple.
- **`Packages.list/2`'s `{:error, _reason} -> []`** — over-broad by inspection, but `list/2` is specced to return a bare list, so there is nowhere to report an error. The catch-all is forced by the signature.

### Naming: three distinct "name" fields

Three unrelated things could each be called a name, so each has its own key. Do not collapse them, and be careful with find-and-replace across `"name"`:

| Key | Where | Means |
|---|---|---|
| `instance_name` | top level of a package / `Spec` field / positional arg of `apply_image/7`, `new_package/3` | The user-facing short name. `Spec.prefix_name/1` derives the container name `dockd-<value>` at the Docker boundary |
| `step_name` | inside a `steps` entry | Display name for one setup step; appears in `:setup` errors and on `StepResult` |
| `name` | inside an `env` entry | The environment variable's own name |

A package's *identity* is none of these — it is the package's directory name, which is what `Dockd.apply_package(root, "greeter", ...)` resolves via `Packages.resolve_path/3`.

`Spec.instance_name` stores the **short** name, and `prefix_name/1` is the one place the `dockd-` prefix is added. `validate/1` rejects a name that already carries the prefix, since `"foo"` and `"dockd-foo"` would otherwise name the same container.

`%Dockd.Instance{}` keeps a plain `:name` field: it is a different struct and `instance.name` is already unambiguous.

The old `"name"` (top level) and `"label"` (step) keys were renamed and are not accepted; both produce a `:validate` error naming the replacement.

### Provisioning pipeline

`Dockd.Provisioner.run/6` takes `(spec, endpoint, disk_mount_enabled, host_env, temp_root, opts)` and runs a sequential pipeline: **validate spec** -> **enforce disk-mount policy** -> **expand env** -> **normalize mounts** -> **validate source** -> **normalize steps/repos/copies** -> **validate tools** -> **build or pull image** -> **create container** -> **start container** -> **fetch repos** -> **copy host files** -> **run setup steps** -> **hydrate Instance**. Each phase is tagged (`:validate`, `:build`, `:pull`, `:create`, `:start`, `:fetch`, `:copy`, `:setup`, `:discover`) so errors report where the failure occurred. When a container was created before the failure, the error carries a hydrated `Dockd.Instance` (and any captured `step_results`) so the caller can clean up with `Dockd.destroy/3`.

`enforce_disk_mount_policy/2` has clauses for `true` and `false` only — deliberately no `nil` clause, because an absent policy must never read as permission to expose the host. `validate_tools/1` runs after the repo/copy specs are normalized, so it knows whether `git` or `tar` is actually needed.

`Provisioner.resolve_env/2` is public: it is the same env resolution the pipeline runs, exposed so the precedence rules are checkable without a daemon. An explicitly-passed `:default` outranks `host_env`.

Outside the pipeline, `Dockd.Error` also uses `:lifecycle` (`start/3`/`stop/3`), `:destroy`, and `:generate` (scaffolding a package to disk).

The image source is determined by `Spec.build`: when set, the image is built locally via `Docker.build_image/5`; otherwise it is pulled from a registry via `Docker.pull_image/3`.

### Key modules

- `Dockd` — the entire public API in one module. `apply/6`, `apply_image/7`, `apply_package/7`, `load_package_spec/3`, `install_packages/3`, `new_package/3`, `list_packages/2`, `delete_package/3`, `list/2`, `get/3`, `destroy/3`, `start/3`, `stop/3`, `restart/3`, `running?/3`, `logs/3`, `inspect/3`, `refresh/3`, `shell_command/4`, `open_shell/3`, `shell_send/3`, `close_shell/2`, `copy_to/5`, `list_temp_files/1`, `delete_temp_files/1`, `option_keys/0`. `install_packages/3` dispatches on the reference: an existing local directory installs from disk, anything else is cloned as a git URL
- `Dockd.Spec` — declarative request type; `new/3` (the only constructor), `validate/1` (the only checker), `validate_instance_name/1` and `fetch_either/2` (both `@doc false`, shared with `Spec.Encoder` and `Provisioner`), `from_attrs/1`, `option_keys/0`, `prefix_name/1`, `short_name/1`
- `Dockd.Spec.Parser` / `.Interpolator` / `.Normalizer` — the JSON-package pipeline: read+parse, `${VAR}` substitution, then attribute normalization
- `Dockd.Spec.Encoder` — the reverse direction: turns an instance name plus caller options into a `package.json` document and pretty-prints it. `document/2`, `encode/1`, `dockerfile/1`, `dockerfile_name/0`, `default_from/0`, `default_image/1`. Pure; `Dockd.Packages.new/3` does the writing. `document/2` and `dockerfile/1` both return `{:ok, _} | {:error, %Dockd.Error{}}`: an **absent** `:image` / `:dockerfile` / `:from` takes the documented default, but one that is present and unusable is a `:validate` error rather than being coerced to that default. `Packages.new/3` builds *both* documents before writing either, so a rejected `:dockerfile` cannot leave a `package.json` behind with no `Dockerfile`
- `Dockd.Instance` — view type; `from_inspect/1`, `managed_labels/1`, `short_name/1`
- `Dockd.Provisioner` — the create-an-Instance pipeline
- `Dockd.Packages` — package storage, with the packages `root` as every function's first argument: `resolve_path/3`, `list/2`, `install_from_git/6`, `install_from_path/3`, `delete/3`, `new/3`
- `Dockd.ApplyResult` — `%{instance, step_results}` returned by `apply/6`. `@enforce_keys [:instance]`: a result without one describes nothing, and a *failed* apply carries its partial instance on the `%Dockd.Error{}` instead
- `Dockd.Git` — clones git repos on the host with a caller-supplied `git_path` and `git_env`, then uploads via `Docker.put_archive/4`. Forces `GIT_TERMINAL_PROMPT=0` so a private URL fails instead of blocking on an invisible credential prompt. It does **not** validate `git_path`/`git_env` types: `download_repos_to_host/7` has exactly one caller, and `Provisioner.validate_tools/1` is the gate in front of it. The only check left here is that the path names a real executable, which `validate_tools/1` does not do
- `Dockd.HostTool` — `@moduledoc false`. The one home for `executable/3`, `env/2`, `staging_root/2`, and `sweepable_root/2`. Returns `:ok | {:error, binary()}`; callers wrap the message in their own phase
- `Dockd.FileCopy` — tars host files/dirs with a caller-supplied `tar_path`/`tar_env` and uploads via `Docker.put_archive/4`; also owns staging-dir housekeeping under a caller-supplied `temp_root`. Archive flags come from `:tar_extra_args`, not `:os.type()`
- `Dockd.Shell` — opens a real interactive TTY for a **human** in a new OS terminal window, so the calling program never surrenders its controlling terminal. `connect_command/4` takes the `docker` path and endpoint and emits `DOCKER_HOST=… docker exec -it …`, so the window targets the daemon the instance actually lives on. Distinct from `Dockd.open_shell/3`, the programmatic non-TTY form
- `Dockd.Ssh` / `Dockd.Ssh.DockerDialStdio` — the remote-daemon path. Renders and installs a wrapper around `docker system dial-stdio` that synthesizes an HTTP 502 when the remote command fails, so the client sees a typed error rather than an opaque EOF. These two are the only modules returning `{:error, binary()}` rather than `{:error, %Dockd.Error{}}`, which is why `Dockd.HostTool` yields a bare message. Neither raises out of that contract: `generate_script/2` reports an unwritable target instead of using `File.write!`, and the script body piped to `ssh` stdin reports a dropped connection instead of matching `:ok = ElixirExec.write(...)`
- `Dockd.Error` — phase-tagged error struct with optional `:instance` and `:step_results`
- `Dockd.StepResult` — captured output and exit code from a single setup step. `@enforce_keys [:step_name, :cmd, :output]` enforces the first three documented data invariants instead of only asserting them in a comment. `:exit_code` is deliberately *not* enforced — `nil` is a real value, meaning Docker reported no status

### No configuration

There is none, deliberately. Dockd reads no environment variable, no application config, no home directory, no CWD, no `System.tmp_dir!()`, no `:os.type()`, and no `PATH`. Every input a function needs arrives as an argument: required ones are positional, genuinely optional ones live in a trailing `opts \\ []` with a **literal** default (never one that reads process state).

Four runtime inputs recur across the public API, none with a default:

| Argument | Was read from | Why it must be explicit |
|---|---|---|
| `endpoint` | `DOCKER_HOST` (in `../docker`) | Decides *which daemon a container is created on* |
| `disk_mount_enabled` | absent meant `true` | Gates host mounts, repo clones, file copies, host env — must fail **closed** |
| `host_env` | `System.get_env/0` | A package can only reach values the caller handed it; `%{}` reaches nothing |
| `temp_root` | `System.tmp_dir!()` | `delete_temp_files/1` deletes recursively; the target must be named |

Host tooling (`:git_path`, `:git_env`, `:tar_path`, `:tar_env`, `:tar_extra_args`, `:container_staging_root`) stays in `opts` because only some specs need it — but a spec with `:repos` or `:copy` and no tooling is a `:validate` error at `Provisioner.validate_tools/1`, never a PATH lookup.

Two functions exist solely so an ambient value can be opted into by name rather than reached implicitly: `Dockd.Shell.default_launcher_path/0` and `Dockd.Ssh.DockerDialStdio.default_template_path/0`. They are the only `:code.priv_dir/1` reads in `lib/`.

There is no option allowlist. `apply/6` reads the keys in `Dockd.option_keys/0` and ignores the rest, as any keyword-option API does. The property that matters is enforced structurally rather than by a rejection list: `endpoint`, `disk_mount_enabled`, `host_env` and `temp_root` are *positional*, so a caller who passes the old `socket: …` or `packages_path: …` option has still had to supply the positional value, and no ambient default exists for the ignored key to revert to.

**Acceptance checks.** Two, and both must stay green:

1. `test/dockd/no_ambient_input_test.exs` — sets `DOCKD_PACKAGES_PATH`, `DOCKER_HOST`, and `config :dockd, packages_path:` to garbage, then drives the package lifecycle purely from arguments. It is the regression test for this whole property, because "the absence of a read" cannot be unit-tested on any single function.
2. This grep, which must return no hits in `lib/` beyond the two `default_*_path/0` functions above (excluding `@doc` examples):

```sh
grep -rnE 'System\.(get_env|fetch_env|user_home|tmp_dir)|Application\.(get|fetch)_env|File\.cwd|code\.priv_dir|:os\.type|System\.(cmd|find_executable)\("' lib/
```

### Docker dependency

The `Docker` module (at `../docker`) provides the low-level API calls. Key functions used by dockd: `pull_image/3`, `build_image/5`, `create_container/4`, `start_container/2`, `stop_container/2`, `delete_container/3`, `put_archive/4`, `list_containers/2`, `find_container/2`, `container_logs/3`, `container_running?/2`, and the `Docker.Terminal` family (`run_with_status/3`, `open/2`, `command/3`, `close/1`).

### Testing

Pure unit tests (no Docker daemon required): `test/dockd/spec_test.exs`, `test/dockd/instance_test.exs`, `test/dockd/spec/*_test.exs` (including `encoder_test.exs`), `test/dockd/apply_opts_test.exs`, `test/dockd/env_test.exs`, `test/dockd/shell_arg_test.exs`, `test/dockd/shell_test.exs`, `test/dockd/ssh_test.exs`, `test/dockd/ssh/*_test.exs`, `test/dockd/open_shell_script_test.exs`.

`test/dockd/env_test.exs` is pure *because* `host_env` is an argument — it no longer needs `System.put_env/2` to set up a case, so it is `async: true`.

`test/dockd/packages_test.exs` is mixed: the scaffolding, listing and local-install tests are pure, while `install_from_git/6` tests are tagged `:integration` (they clone from a `file://` URL, so they need `git` but not Docker). Its `Dockd.new_package/3` block also owns the two end-to-end scaffolder-gate tests — that a `dockd-`-prefixed name and mutually-exclusive `:env` options are both rejected *and write nothing to disk*. Those assert on `Dockd.Spec` and `Dockd.Spec.Normalizer` messages respectively, because that is where each rule now lives; `spec/encoder_test.exs` deliberately no longer re-checks either.

`test/dockd_test.exs` needs a running daemon for all but ~18 of its tests. Its helpers at the bottom of the file are where the suite decides what to pass for `endpoint`, `temp_root`, `host_env`, and the host tooling — a test *may* discover these from the environment; the library may not.

Integration tests requiring a running Docker daemon: `test/dockd_test.exs`, `test/dockd/env_test.exs`, `test/dockd/packages_test.exs`. They use `busybox:1.37.0` as the test image. With no daemon reachable these fail with `:endpoint_not_resolved`.

Test fixtures (e.g. a minimal Dockerfile) live in `test/fixtures/`.
