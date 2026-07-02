# Claude Code Package Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert `apps/dockd_claude_code` from a code-generating OTP app into a static top-level `packages/` data tree, and add a local-path install path to `Dockd.Packages`.

**Architecture:** A package is data on disk (`packages/<name>/package.json` + `Dockerfile`), materialized into the packages root by `apps/dockd`. We delete the `dockd_claude_code` app, check the four claude_code packages in as static files, add `Dockd.Packages.install_from_path/2` (git-install minus the clone), and wire a `local` source type into the existing `mix dockd.package.install` task.

**Tech Stack:** Elixir umbrella (Mix), ExUnit.

## Global Constraints

- On-disk package format is unchanged: `<root>/packages/<name>/package.json` (a serialized `Dockd.Spec`) plus supporting files (e.g. `Dockerfile`).
- No changes to `Dockd.Spec`, the provisioning pipeline, or the package format.
- No shared-Dockerfile mechanism — each package dir carries its own `Dockerfile`.
- The umbrella uses `apps_path: "apps"`; removing an app directory drops it from the umbrella with no config edit.
- Both install source types share the single `--source` flag: `git --source=URL`, `local --source=DIR`.
- `mix format` and existing tests must stay green.

---

### Task 1: Add the static `packages/` data tree

Replaces the `@packages`/`@dockerfile`/`@env` module attributes with checked-in JSON + Dockerfile files at the repo top level.

**Files:**
- Create: `packages/claude_code/package.json`
- Create: `packages/claude_code/Dockerfile`
- Create: `packages/claude_code_live_workspace/package.json`
- Create: `packages/claude_code_live_workspace/Dockerfile`
- Create: `packages/claude_code_isolated_workspace/package.json`
- Create: `packages/claude_code_isolated_workspace/Dockerfile`
- Create: `packages/claude_code_repo_workspace/package.json`
- Create: `packages/claude_code_repo_workspace/Dockerfile`

**Interfaces:**
- Produces: a top-level `packages/` directory matching what `Dockd.Packages.install_from_clone/2` expects (`<root>/packages/<name>/package.json`). Task 2's smoke test and Task 4's local install consume it.

- [ ] **Step 1: Write the shared Dockerfile content into all four package dirs**

Each `Dockerfile` (identical, one per package dir) contains exactly:

```dockerfile
FROM node:20-slim
RUN npm install -g @anthropic-ai/claude-code
```

- [ ] **Step 2: Write `packages/claude_code/package.json`**

The `env` array below is shared verbatim across all four package.json files.

```json
{
  "name": "claude_code",
  "description": "Anthropic Claude Code CLI with the current working directory mounted at /instance and host Claude credentials shared in.",
  "image": "dockd/claude-code:latest",
  "shell": "claude",
  "build": { "dockerfile": "Dockerfile" },
  "mounts": [
    "${PWD}:/instance",
    "${HOME}/.claude:/root/.claude",
    "${HOME}/.claude.json:/root/.claude.json"
  ],
  "env": [
    { "name": "ANTHROPIC_API_KEY", "optional": true },
    { "name": "CLAUDE_CODE_OAUTH_TOKEN", "optional": true },
    { "name": "AWS_ACCESS_KEY_ID", "optional": true },
    { "name": "AWS_SECRET_ACCESS_KEY", "optional": true },
    { "name": "AWS_SESSION_TOKEN", "optional": true },
    { "name": "AWS_REGION", "optional": true }
  ]
}
```

- [ ] **Step 3: Write `packages/claude_code_live_workspace/package.json`**

```json
{
  "name": "claude_code_live_workspace",
  "description": "Claude Code CLI with the current working directory live-mounted at /instance and host Claude credentials shared in.",
  "image": "dockd/claude-code:latest",
  "shell": "claude",
  "build": { "dockerfile": "Dockerfile" },
  "mounts": [
    "${PWD}:/instance",
    "${HOME}/.claude:/root/.claude",
    "${HOME}/.claude.json:/root/.claude.json"
  ],
  "env": [
    { "name": "ANTHROPIC_API_KEY", "optional": true },
    { "name": "CLAUDE_CODE_OAUTH_TOKEN", "optional": true },
    { "name": "AWS_ACCESS_KEY_ID", "optional": true },
    { "name": "AWS_SECRET_ACCESS_KEY", "optional": true },
    { "name": "AWS_SESSION_TOKEN", "optional": true },
    { "name": "AWS_REGION", "optional": true }
  ]
}
```

- [ ] **Step 4: Write `packages/claude_code_isolated_workspace/package.json`**

```json
{
  "name": "claude_code_isolated_workspace",
  "description": "Claude Code CLI running in an isolated workspace with the host project copied into /instance/project and an output volume mounted from ~/dockd-output.",
  "image": "dockd/claude-code:latest",
  "shell": "claude",
  "build": { "dockerfile": "Dockerfile" },
  "env": [
    { "name": "ANTHROPIC_API_KEY", "optional": true },
    { "name": "CLAUDE_CODE_OAUTH_TOKEN", "optional": true },
    { "name": "AWS_ACCESS_KEY_ID", "optional": true },
    { "name": "AWS_SECRET_ACCESS_KEY", "optional": true },
    { "name": "AWS_SESSION_TOKEN", "optional": true },
    { "name": "AWS_REGION", "optional": true }
  ],
  "mounts": [
    "${HOME}/dockd-output:/instance/output"
  ],
  "copy": [
    { "src": "${PWD}", "dest": "/instance/project" }
  ],
  "steps": [
    { "label": "scaffold output dir", "cmd": ["mkdir", "-p", "/instance/output"] }
  ]
}
```

- [ ] **Step 5: Write `packages/claude_code_repo_workspace/package.json`**

```json
{
  "name": "claude_code_repo_workspace",
  "description": "Claude Code CLI in a workspace populated by cloning ${DOCKD_REPO_URL} into /instance/repo with an output volume mounted from ~/dockd-output.",
  "image": "dockd/claude-code:latest",
  "shell": "claude",
  "build": { "dockerfile": "Dockerfile" },
  "env": [
    { "name": "ANTHROPIC_API_KEY", "optional": true },
    { "name": "CLAUDE_CODE_OAUTH_TOKEN", "optional": true },
    { "name": "AWS_ACCESS_KEY_ID", "optional": true },
    { "name": "AWS_SECRET_ACCESS_KEY", "optional": true },
    { "name": "AWS_SESSION_TOKEN", "optional": true },
    { "name": "AWS_REGION", "optional": true }
  ],
  "mounts": [
    "${HOME}/dockd-output:/instance/output"
  ],
  "repos": [
    { "url": "${DOCKD_REPO_URL}", "ref": "${DOCKD_REPO_REF:-main}", "dest": "/instance/repo" }
  ],
  "steps": [
    { "label": "scaffold output dir", "cmd": ["mkdir", "-p", "/instance/output"] }
  ]
}
```

- [ ] **Step 6: Verify the tree exists and JSON is valid**

Run: `for f in packages/*/package.json; do python3 -m json.tool "$f" >/dev/null && echo "ok $f"; done`
Expected: eight lines? No — four `ok packages/<name>/package.json` lines, one per package.

- [ ] **Step 7: Commit**

```bash
git add packages/
git commit -m "feat: add static claude_code package data tree"
```

---

### Task 2: Add `install_from_path/2` to `Dockd.Packages` + smoke test the shipped data

Adds the local-path install (git-install minus clone) and a data-drift guard.

**Files:**
- Modify: `apps/dockd/lib/dockd/packages.ex` (add `install_from_path/2` near `install_from_git/2`, ~line 146)
- Test: `apps/dockd/test/dockd/packages_test.exs` (add two describe blocks)

**Interfaces:**
- Consumes: existing private `install_from_clone/2` in `apps/dockd/lib/dockd/packages.ex` (takes a directory, finds its `packages/` subdir, validates each `package.json` parses as a `Dockd.Spec`, copies each into `dest_dir`).
- Produces: `Dockd.Packages.install_from_path(dir :: binary(), opts :: keyword()) :: {:ok, [binary()]} | {:error, Dockd.Error.t()}`. `opts` accepts `:dest_dir` and `:packages_path` exactly like `install_from_git/2`. Task 4's CLI task consumes it.

- [ ] **Step 1: Write the failing tests**

Add to `apps/dockd/test/dockd/packages_test.exs`, before the final `defp make_repo` (helpers `add_package`/`sandbox_dir` already exist and are reused):

```elixir
  describe "install_from_path/2" do
    test "installs every packages/<name>/ dir from a local directory" do
      src = sandbox_dir("dockd-local-src")
      dest = sandbox_dir("dockd-local-dest")

      add_package(src, "alpha", ~s({"name": "alpha", "image": "busybox:1.37.0"}))

      add_package(src, "beta", ~s({"name": "beta", "image": "busybox:1.37.0"}),
        dockerfile: "FROM busybox\n"
      )

      assert {:ok, names} = Packages.install_from_path(src, dest_dir: dest)

      assert Enum.sort(names) === ["alpha", "beta"]
      assert File.exists?(Path.join([dest, "alpha", "package.json"]))
      assert File.exists?(Path.join([dest, "beta", "Dockerfile"]))
    end

    test "errors when the directory has no packages/ subdir" do
      src = sandbox_dir("dockd-local-empty")
      File.mkdir_p!(src)
      dest = sandbox_dir("dockd-local-empty-dest")

      assert {:error, err} = Packages.install_from_path(src, dest_dir: dest)
      assert err.phase === :fetch
      assert err.message =~ "no top-level packages/ directory"
    end
  end

  describe "shipped claude_code package data" do
    test "every shipped package installs (i.e. its package.json parses as a Spec)" do
      # Repo root = four levels up from this test file
      # (apps/dockd/test/dockd -> apps/dockd/test -> apps/dockd -> apps -> repo root).
      repo_root = Path.expand(Path.join([__DIR__, "..", "..", "..", ".."]))
      dest = sandbox_dir("dockd-shipped-dest")

      assert {:ok, names} = Packages.install_from_path(repo_root, dest_dir: dest)

      for name <- [
            "claude_code",
            "claude_code_live_workspace",
            "claude_code_isolated_workspace",
            "claude_code_repo_workspace"
          ] do
        assert name in names, "shipped package #{name} did not install/parse"
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apps/dockd && mix test test/dockd/packages_test.exs -v`
Expected: all three new tests FAIL with `UndefinedFunctionError` (function `Dockd.Packages.install_from_path/2` is undefined). The pre-existing tests still pass.

- [ ] **Step 3: Add `install_from_path/2`**

Insert into `apps/dockd/lib/dockd/packages.ex` immediately after the `install_from_git/2` function (after its closing `end`, before `defp install_from_clone`):

```elixir
  @doc """
  Installs every package under a local directory's `packages/` subdir into
  the configured packages root.

  Identical to `install_from_git/2` without the clone: `dir` must contain a
  `packages/<name>/` tree where each package dir holds a `package.json` that
  parses as a `Dockd.Spec`. Returns `{:ok, [name]}` or a `:fetch`-tagged
  `Dockd.Error`.

  Options:

    - `:packages_path` — override the configured packages root.
    - `:dest_dir` — override the install root. Primarily used by tests.
  """
  @spec install_from_path(binary(), keyword()) ::
          {:ok, [binary()]} | {:error, Error.t()}
  def install_from_path(dir, opts \\ []) when is_binary(dir) do
    dest_dir = Keyword.get(opts, :dest_dir, packages_root(opts))
    install_from_clone(dir, dest_dir)
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd apps/dockd && mix test test/dockd/packages_test.exs`
Expected: PASS (all describe blocks).

- [ ] **Step 5: Commit**

```bash
git add apps/dockd/lib/dockd/packages.ex apps/dockd/test/dockd/packages_test.exs
git commit -m "feat: add Dockd.Packages.install_from_path and shipped-data smoke test"
```

---

### Task 3: Delete the `dockd_claude_code` app

Removes the generator app now that its data lives in `packages/` and install is owned by `apps/dockd`.

**Files:**
- Delete: `apps/dockd_claude_code/` (entire directory)

**Interfaces:**
- Consumes: nothing. Produces: nothing. This task removes the app that Task 4's CLI help/text must stop referencing.

- [ ] **Step 1: Confirm no code outside the app depends on it**

Run: `grep -rn "Dockd.ClaudeCode\|dockd_claude_code\|dockd.claude_code" apps config mix.exs --include=*.ex --include=*.exs | grep -v "apps/dockd_claude_code/"`
Expected: only matches in `apps/dockd_cli/lib/mix/tasks/dockd.ex` and `apps/dockd_cli/test/mix/tasks/dockd_test.exs` (handled in Task 4). No matches under `apps/dockd/lib` or `config/`.

- [ ] **Step 2: Delete the app directory**

Run: `git rm -r apps/dockd_claude_code`
Expected: the five source/test files plus `mix.exs` are staged for deletion.

- [ ] **Step 3: Verify the umbrella still compiles**

Run: `mix compile`
Expected: compiles with no error about a missing `:dockd_claude_code` app.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor: delete dockd_claude_code app in favor of static package data"
```

---

### Task 4: Wire `local` source into `mix dockd.package.install` and fix CLI help

Adds the `local --source=DIR` branch and removes dangling `mix dockd.claude_code.install` references.

**Files:**
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.package.install.ex` (add `local` branch + docs)
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.ex:21` and `:42` (replace claude_code.install help entries)
- Test: `apps/dockd_cli/test/mix/tasks/dockd_test.exs:30` (update expected help text)

**Interfaces:**
- Consumes: `Dockd.Packages.install_from_path/2` (Task 2) and existing `Dockd.Packages.install_from_git/2`.

- [ ] **Step 1: Update the `mix dockd` help test to expect the new command**

In `apps/dockd_cli/test/mix/tasks/dockd_test.exs`, replace the line
`            "mix dockd.claude_code.install",`
with
`            "mix dockd.package.install",`
(Note: `"mix dockd.package.install"` may already be in the list below it — if so, delete the `claude_code.install` line rather than duplicating.)

- [ ] **Step 2: Run the help test to verify it fails**

Run: `cd apps/dockd_cli && mix test test/mix/tasks/dockd_test.exs -v`
Expected: currently PASSES against old text; after the edit it will FAIL only if the help source still lists `claude_code.install` in a way the test no longer asserts — proceed to make source match. Run again after Step 3.

- [ ] **Step 3: Fix `apps/dockd_cli/lib/mix/tasks/dockd.ex` help entries**

Replace the `@moduledoc` line (`:21`):
`      mix dockd.claude_code.install - Generate Claude Code packages`
with:
`      mix dockd.package.install local --source=DIR - Install packages from a local dir`

Replace the `@subtasks` entry (`:42`):
`    {"mix dockd.claude_code.install", "Generate Claude Code packages"},`
with:
`    {"mix dockd.package.install <source>", "Install packages from a git or local source"},`

If this produces a duplicate `mix dockd.package.install <source>` entry (the list already has one at `:43`), delete the now-redundant original at `:43` instead of leaving two.

- [ ] **Step 4: Add the `local` branch to the install task**

In `apps/dockd_cli/lib/mix/tasks/dockd.package.install.ex`, replace the `@moduledoc`'s "Currently only `git` is supported..." paragraph and the `case source_type do` block. New `@moduledoc` body (replace from "Currently only" through the `## Examples` block):

```elixir
  Two source types are supported:

    - `git --source=<url>` clones a remote repo (HTTPS, SSH, or the
      `github.com/user/repo` shorthand) and installs every
      `<repo>/packages/<name>/` that contains a `package.json`.
    - `local --source=<dir>` installs every `<dir>/packages/<name>/`
      that contains a `package.json` from a local directory.

  Existing packages with the same name are overwritten.

  ## Examples

      mix dockd.package.install git --source=https://github.com/user/recipes
      mix dockd.package.install git --source=github.com/user/recipes
      mix dockd.package.install local --source=.
```

Replace the result `case source_type do` block:

```elixir
    result =
      case source_type do
        "git" ->
          Dockd.Packages.install_from_git(url, [])

        "local" ->
          Dockd.Packages.install_from_path(url, [])

        other ->
          Mix.raise("Unsupported source #{inspect(other)} (supported: git, local)")
      end
```

(The existing `url = opts[:source] || Mix.raise(...)` binding already provides `--source` for both branches; no other change needed. The `Missing required source argument` message should read `(supported: git, local)` — update that `Mix.raise` string too.)

- [ ] **Step 5: Run the affected tests**

Run: `cd apps/dockd_cli && mix test test/mix/tasks/dockd_test.exs`
Expected: PASS.

- [ ] **Step 6: Format and run the full suite (non-integration)**

Run: `mix format && mix test --exclude integration`
Expected: PASS, no formatting diff.

- [ ] **Step 7: Commit**

```bash
git add apps/dockd_cli
git commit -m "feat: support local source in dockd.package.install; drop claude_code.install references"
```

---

## Self-Review

**Spec coverage:**
- Delete app → Task 3. ✅
- Static `packages/` tree with per-dir Dockerfile → Task 1. ✅
- `install_from_path/2` reusing `install_from_clone/2` → Task 2. ✅
- `local --source=DIR` on existing task, unified `--source` flag → Task 4. ✅
- CLI help cleanup (`dockd.ex`) → Task 4. ✅
- Unit test for `install_from_path/2` (no network) → Task 2. ✅
- Smoke test that shipped package.json files parse (via `install_from_path` into a temp dest), repo root anchored off `__DIR__` → Task 2. ✅
- Doc examples referencing `claude_code*` presets remain valid (no task needed, they assume install-first). ✅

**Placeholder scan:** No TBD/TODO; every code step shows full content. Step 6 of Task 1 wording fixed to state "four lines."

**Type consistency:** `install_from_path/2` signature and `:dest_dir`/`:packages_path` opts match `install_from_git/2` usage in Task 2 tests and Task 4 calls. The smoke test deliberately avoids reaching for a public `Spec.from_json_file/1` (which does not exist — parsing is done by the private `load_metadata_spec/1` pipeline inside `Dockd.Packages`); it validates parsing through `install_from_path/2` instead, which is the real code path.
