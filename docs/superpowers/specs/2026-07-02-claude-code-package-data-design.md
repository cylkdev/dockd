# Turn `dockd_claude_code` into pure package data

**Date:** 2026-07-02
**Status:** Approved design, pending implementation

## Problem

`apps/dockd_claude_code/lib/dockd_claude_code/packages.ex` holds four package
definitions as Elixir module attributes (`@packages`, `@dockerfile`, `@env`) and
ships a generator (`generate/1`, `packages_root/1`, force-handling, mkdir,
JSON-encoding) plus a `mix dockd.claude_code.install` task that writes those
attributes to disk.

This re-implements a concern `apps/dockd` already owns. `Dockd.Packages`
already defines a package as **data on disk** — a `<root>/packages/<name>/`
directory containing a `package.json` (a serialized `Dockd.Spec`) plus
supporting files such as a `Dockerfile` — and already knows how to materialize
packages into the packages root via `install_from_git/2` →
`install_from_clone/2`.

Keeping the claude_code definitions trapped in Elixir code, with a parallel
generator, means `dockd_claude_code` knows things only `apps/dockd` should know.
A package should be downloadable JSON data, and `dockd_claude_code` should only
*be* such a package — not contain install machinery.

## Core principle

A package is data on disk, not compiled code. `apps/dockd` owns materializing
and reading packages. `dockd_claude_code` stops being an OTP app and becomes a
checked-in `packages/` tree that any install path (git or local) copies into the
packages root.

## Changes

### 1. Delete `apps/dockd_claude_code/` entirely

Remove the whole app directory:

- `apps/dockd_claude_code/mix.exs`
- `apps/dockd_claude_code/lib/dockd_claude_code/packages.ex` (generator + attributes)
- `apps/dockd_claude_code/lib/mix/tasks/dockd.claude_code.install.ex`
- `apps/dockd_claude_code/test/dockd/claude_code/packages_test.exs`
- `apps/dockd_claude_code/test/mix/tasks/dockd_claude_code_install_test.exs`
- `apps/dockd_claude_code/test/test_helper.exs`

The umbrella uses `apps_path: "apps"`, so removing the directory drops it from
the umbrella automatically — no config edit required.

### 2. Add a static top-level `packages/` tree

```
packages/
  claude_code/                     package.json  Dockerfile
  claude_code_live_workspace/      package.json  Dockerfile
  claude_code_isolated_workspace/  package.json  Dockerfile
  claude_code_repo_workspace/      package.json  Dockerfile
```

- Each `package.json` is the literal map previously held in `@packages`, with
  the shared `env` list inlined.
- Each `Dockerfile` is the previous `@dockerfile` content, duplicated into every
  package dir. Packages must be self-contained because install copies the whole
  directory; four small identical Dockerfiles is the correct cost of packages
  being standalone data.
- The location matches exactly what `install_from_clone/2` expects
  (`<root>/packages/<name>/`), so this repo is directly installable via
  `install_from_git` against its GitHub URL as well.

### 3. Add local-path install to `Dockd.Packages`

```elixir
def install_from_path(dir, opts \\ []) when is_binary(dir) do
  dest_dir = Keyword.get(opts, :dest_dir, packages_root(opts))
  install_from_clone(dir, dest_dir)   # already looks for <dir>/packages/
end
```

`install_from_clone/2` already takes a directory, finds its `packages/` subdir,
validates each `package.json` parses as a `Dockd.Spec`, and copies it into the
dest root. Local install is git-install minus the clone.

Expose it through the existing task with a new source type, reusing the
existing `--source` flag for both source types:

```
mix dockd.package.install local --source=DIR
mix dockd.package.install git   --source=URL
```

`--source` means "where the packages come from"; the positional source-type
word (`local` vs `git`) disambiguates a filesystem path from a clone URL, so no
second flag is introduced. `apps/dockd_cli/lib/mix/tasks/dockd.package.install.ex`
gains a `local` branch that calls `Dockd.Packages.install_from_path(source)`,
alongside the existing `git` branch.

### 4. Cleanup of dangling references

- `apps/dockd_cli/lib/mix/tasks/dockd.ex` — replace the two
  `mix dockd.claude_code.install` help entries with the local-install command.
- Doc examples referencing `claude_code*` presets
  (`apps/dockd_cli/lib/mix/tasks/dockd.instance.run.ex`, `apps/dockd/lib/dockd.ex`)
  remain valid; they assume the package is already installed.

## Testing

- Unit-test `install_from_path/2` against a fixture directory containing
  `packages/<name>/package.json`, asserting the package dirs land in a temp dest
  root. Mirrors the existing git-install test but with no network.
- Smoke-test that each shipped `packages/claude_code*/package.json` parses as a
  valid `Dockd.Spec`, guarding the static data against drift. Resolve the
  `packages/` path relative to the umbrella root (anchored off `__DIR__`), not
  the process cwd, so the test passes whether `mix test` runs from the umbrella
  root or the app directory.
- Update/replace CLI task tests that assert on `mix dockd.claude_code.install`
  help text.

## Out of scope

- No changes to `Dockd.Spec`, the provisioning pipeline, or the on-disk package
  format.
- No shared-Dockerfile mechanism; duplication per package dir is intentional.
