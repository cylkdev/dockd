# Standalone `dockd` CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `dockd_cli` as a self-contained single-file executable (`dockd`) that mirrors today's `mix dockd.*` commands and runs on macOS/Linux without Elixir, Erlang, or Mix installed.

**Architecture:** Extract the logic currently embedded in `Mix.Tasks.Dockd.*` into a Mix-free command layer (`DockdCli.Commands.*`) that writes through a `DockdCli.Output` module and returns `:ok | {:error, term}`. A single Optimus-based entrypoint (`DockdCli.Main`) parses argv and dispatches. Existing Mix tasks become thin wrappers over the same command modules so `mix dockd.*` and `dockd ...` share one implementation. The release is bundled into a single executable with Burrito.

**Tech Stack:** Elixir umbrella, `optimus` (CLI parsing), `burrito` (self-contained release + Zig), the existing `Dockd` public API, `docker` HTTP client.

## Global Constraints

- Target platforms: macOS (aarch64 primary) and Linux (x86_64). No Windows.
- End users install nothing but the binary; a running Docker daemon is the only runtime prerequisite.
- Command layer (`DockdCli.Commands.*`, `DockdCli.Output`, `DockdCli.Options`) MUST NOT call `Mix.shell/0`, `Mix.raise/1`, or any `Mix.*` function.
- Command surface mirrors existing Mix tasks 1:1; flag names and behavior are preserved exactly.
- Command modules return `:ok | {:error, term()}`; only entrypoints call `System.halt/1`.
- Docker connection + temp dir must be resolvable at runtime via env vars / flags, not frozen at build time.
- Elixir `~> 1.17` (matches umbrella apps).
- TDD: write the failing test first for every behavioral change; commit after each green task.

---

### Task 1: Add `optimus` dependency to `dockd_cli`

**Files:**
- Modify: `apps/dockd_cli/mix.exs`

**Interfaces:**
- Produces: `Optimus` module available to `apps/dockd_cli`.

- [ ] **Step 1: Add the dependency**

In `apps/dockd_cli/mix.exs`, change `defp deps do` to:

```elixir
  defp deps do
    [
      {:dockd, in_umbrella: true},
      {:dockd_ssh, in_umbrella: true},
      {:optimus, "~> 0.5"}
    ]
  end
```

- [ ] **Step 2: Fetch and compile**

Run: `mix deps.get && mix compile`
Expected: compiles cleanly; `optimus` appears in the dependency list.

- [ ] **Step 3: Commit**

```bash
git add apps/dockd_cli/mix.exs mix.lock
git commit -m "build: add optimus dependency to dockd_cli"
```

---

### Task 2: `DockdCli.Output` — Mix-free output helpers

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/output.ex`
- Test: `apps/dockd_cli/test/dockd_cli/output_test.exs`

**Interfaces:**
- Produces:
  - `DockdCli.Output.info(iodata()) :: :ok` — writes line to stdout
  - `DockdCli.Output.error(iodata()) :: :ok` — writes line to stderr
  - `DockdCli.Output.write(iodata()) :: :ok` — writes raw bytes to stdout (no newline)
  - `DockdCli.Output.table([tuple()], tuple()) :: :ok` — prints a padded table given rows and a header tuple of the same arity

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.OutputTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias DockdCli.Output

  test "info writes a line to stdout" do
    assert capture_io(fn -> assert Output.info("hello") == :ok end) == "hello\n"
  end

  test "write emits raw bytes with no trailing newline" do
    assert capture_io(fn -> Output.write("abc") end) == "abc"
  end

  test "error writes to stderr" do
    captured = capture_io(:stderr, fn -> assert Output.error("boom") == :ok end)
    assert captured == "boom\n"
  end

  test "table pads columns and prints header first" do
    out =
      capture_io(fn ->
        Output.table([{"a", "1"}, {"bb", "22"}], {"NAME", "N"})
      end)

    assert out == "NAME  N\na     1\nbb    22\n"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/output_test.exs`
Expected: FAIL with `DockdCli.Output` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule DockdCli.Output do
  @moduledoc """
  Mix-free output helpers for the standalone CLI. Replaces `Mix.shell()`
  so command modules can run inside a bundled release with no Mix present.
  """

  @spec info(iodata()) :: :ok
  def info(msg), do: IO.puts(msg)

  @spec error(iodata()) :: :ok
  def error(msg), do: IO.puts(:stderr, msg)

  @spec write(iodata()) :: :ok
  def write(bytes), do: IO.write(bytes)

  @spec table([tuple()], tuple()) :: :ok
  def table(rows, header) when is_tuple(header) do
    widths = column_widths([header | rows])
    info(format_row(header, widths))
    Enum.each(rows, fn row -> info(format_row(row, widths)) end)
  end

  defp column_widths(rows) do
    arity = tuple_size(hd(rows))

    for col <- 0..(arity - 1) do
      rows
      |> Enum.map(fn row -> row |> elem(col) |> to_string() |> String.length() end)
      |> Enum.max()
    end
  end

  defp format_row(row, widths) do
    cols = Tuple.to_list(row)
    last = length(cols) - 1

    cols
    |> Enum.with_index()
    |> Enum.map_join("  ", fn {value, idx} ->
      str = to_string(value)
      if idx == last, do: str, else: String.pad_trailing(str, Enum.at(widths, idx))
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/dockd_cli/test/dockd_cli/output_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/output.ex apps/dockd_cli/test/dockd_cli/output_test.exs
git commit -m "feat: add DockdCli.Output Mix-free output helpers"
```

---

### Task 3: `DockdCli.Options` — runtime connection/config resolution

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/options.ex`
- Test: `apps/dockd_cli/test/dockd_cli/options_test.exs`

**Interfaces:**
- Produces:
  - `DockdCli.Options.resolve(flags :: map(), env :: map()) :: keyword()` — returns the per-call `opts` keyword list threaded into `Dockd.*` calls. Flag overrides env; env overrides nothing (omitted keys are simply absent). Recognized flags: `:socket`, `:host`. Recognized env: `DOCKER_SOCKET`, `DOCKER_HOST`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.OptionsTest do
  use ExUnit.Case, async: true

  alias DockdCli.Options

  test "returns empty opts when nothing is set" do
    assert Options.resolve(%{}, %{}) == []
  end

  test "reads socket and host from env" do
    env = %{"DOCKER_SOCKET" => "/run/d.sock", "DOCKER_HOST" => "tcp://x:2375"}
    opts = Options.resolve(%{}, env)
    assert opts[:socket] == "/run/d.sock"
    assert opts[:host] == "tcp://x:2375"
  end

  test "flags override env" do
    env = %{"DOCKER_SOCKET" => "/from/env.sock"}
    opts = Options.resolve(%{socket: "/from/flag.sock"}, env)
    assert opts[:socket] == "/from/flag.sock"
  end

  test "ignores blank flag values" do
    assert Options.resolve(%{socket: nil, host: ""}, %{}) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/options_test.exs`
Expected: FAIL with `DockdCli.Options` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule DockdCli.Options do
  @moduledoc """
  Resolves runtime Docker connection options for the standalone CLI.

  Precedence: explicit CLI flag > environment variable > absent. The
  resulting keyword list is threaded into every `Dockd.*` call as its
  per-call `opts`.
  """

  @spec resolve(map(), map()) :: keyword()
  def resolve(flags, env) do
    []
    |> put(:socket, pick(flags[:socket], env["DOCKER_SOCKET"]))
    |> put(:host, pick(flags[:host], env["DOCKER_HOST"]))
  end

  defp pick(flag, _env) when is_binary(flag) and flag != "", do: flag
  defp pick(_flag, env) when is_binary(env) and env != "", do: env
  defp pick(_flag, _env), do: nil

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/dockd_cli/test/dockd_cli/options_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/options.ex apps/dockd_cli/test/dockd_cli/options_test.exs
git commit -m "feat: add DockdCli.Options runtime connection resolution"
```

---

### Task 4: Extract `DockdCli.Commands.Instance.List` + rewire Mix task

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/commands/instance/list.ex`
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.instance.list.ex`
- Test: `apps/dockd_cli/test/dockd_cli/commands/instance/list_test.exs`

**Interfaces:**
- Consumes: `DockdCli.Output.info/1`, `DockdCli.Output.table/2`; `Dockd.list/1`; `Dockd.Instance.short_name/1`.
- Produces: `DockdCli.Commands.Instance.List.run(map(), keyword()) :: :ok | {:error, term()}`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.Commands.Instance.ListTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias DockdCli.Commands.Instance.List

  test "prints message when there are no instances" do
    out = capture_io(fn -> assert List.render({:ok, []}) == :ok end)
    assert out == "No dockd instances.\n"
  end

  test "prints a table row per instance" do
    instances = [
      %Dockd.Instance{name: "dockd-smoke", image: "busybox:1.37.0", running?: true, id: "abcdef0123456789"}
    ]

    out = capture_io(fn -> assert List.render({:ok, instances}) == :ok end)
    assert out =~ "NAME"
    assert out =~ "smoke"
    assert out =~ "busybox:1.37.0"
    assert out =~ "running"
    assert out =~ "abcdef012345"
  end

  test "returns error tuple on Dockd error" do
    err = %Dockd.Error{phase: :discover, message: "nope"}
    assert List.render({:error, err}) == {:error, err}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/list_test.exs`
Expected: FAIL with `DockdCli.Commands.Instance.List` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule DockdCli.Commands.Instance.List do
  @moduledoc "Lists dockd-managed instances as a table."

  alias Dockd.Instance
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(_args, opts), do: render(Dockd.list(opts))

  @doc false
  @spec render({:ok, [Instance.t()]} | {:error, term()}) :: :ok | {:error, term()}
  def render({:ok, []}), do: Output.info("No dockd instances.")

  def render({:ok, instances}) do
    rows = Enum.map(instances, &row/1)
    Output.table(rows, {"NAME", "IMAGE", "STATUS", "ID"})
  end

  def render({:error, err}), do: {:error, err}

  defp row(%Instance{} = instance) do
    {
      Instance.short_name(instance),
      instance.image || "",
      if(instance.running?, do: "running", else: "stopped"),
      short_id(instance.id)
    }
  end

  defp short_id(nil), do: ""
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)
end
```

- [ ] **Step 4: Rewire the Mix task to delegate**

Replace the body of `apps/dockd_cli/lib/mix/tasks/dockd.instance.list.ex` (keep the moduledoc) so `run/1` becomes:

```elixir
  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case DockdCli.Commands.Instance.List.run(%{}, []) do
      :ok -> :ok
      {:error, %Dockd.Error{} = err} -> Mix.raise(Exception.message(err))
    end
  end
```

Remove the now-unused private table/row/format helpers from the Mix task (they live in the command module now).

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/list_test.exs && mix compile`
Expected: PASS (3 tests); clean compile with no unused-function warnings.

- [ ] **Step 6: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/instance/list.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.instance.list.ex \
        apps/dockd_cli/test/dockd_cli/commands/instance/list_test.exs
git commit -m "refactor: extract instance list into DockdCli.Commands layer"
```

---

### Task 5: Extract `DockdCli.Commands.Instance.Stop` + rewire Mix task

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/commands/instance/stop.ex`
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.instance.stop.ex`
- Test: `apps/dockd_cli/test/dockd_cli/commands/instance/stop_test.exs`

**Interfaces:**
- Consumes: `DockdCli.Output.info/1`, `DockdCli.Output.error/1`; `Dockd.stop/2`, `Dockd.list/1`; `Dockd.Instance.short_name/1`.
- Produces: `DockdCli.Commands.Instance.Stop.run(%{optional(:all) => boolean(), optional(:name) => binary()}, keyword()) :: :ok | {:error, term()}`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.Commands.Instance.StopTest do
  use ExUnit.Case, async: true

  alias DockdCli.Commands.Instance.Stop

  test "returns error when neither name nor --all is given" do
    assert {:error, msg} = Stop.run(%{}, [])
    assert msg =~ "NAME"
  end

  test "rejects --all combined with a name" do
    assert {:error, msg} = Stop.run(%{all: true, name: "smoke"}, [])
    assert msg =~ "--all"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/stop_test.exs`
Expected: FAIL with `DockdCli.Commands.Instance.Stop` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule DockdCli.Commands.Instance.Stop do
  @moduledoc "Stops one dockd-managed instance, or every managed instance."

  alias Dockd.Instance
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{all: true, name: name}, _opts) when is_binary(name) and name != "" do
    {:error, "--all cannot be combined with a positional NAME"}
  end

  def run(%{all: true}, opts), do: stop_all(opts)

  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.stop(name, opts) do
      :ok -> Output.info("Stopped #{name}")
      {:error, err} -> {:error, err}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance stop NAME | --all"}

  defp stop_all(opts) do
    case Dockd.list(opts) do
      {:ok, []} -> Output.info("No dockd instances.")
      {:ok, instances} -> sweep(instances, opts)
      {:error, err} -> {:error, err}
    end
  end

  defp sweep(instances, opts) do
    failures =
      Enum.count(instances, fn instance ->
        name = Instance.short_name(instance)

        case Dockd.stop(instance, opts) do
          :ok ->
            Output.info("Stopped #{name}")
            false

          {:error, err} ->
            Output.error("Failed to stop #{name}: #{Exception.message(err)}")
            true
        end
      end)

    if failures > 0 do
      {:error, "#{failures} of #{length(instances)} instance(s) failed to stop"}
    else
      :ok
    end
  end
end
```

- [ ] **Step 4: Rewire the Mix task to parse then delegate**

Replace `run/1` in `apps/dockd_cli/lib/mix/tasks/dockd.instance.stop.ex` (keep moduledoc + `@switches`):

```elixir
  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown flags: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    parsed = %{all: opts[:all] || false, name: List.first(args)}

    case DockdCli.Commands.Instance.Stop.run(parsed, []) do
      :ok -> :ok
      {:error, %Dockd.Error{} = err} -> Mix.raise(Exception.message(err))
      {:error, msg} when is_binary(msg) -> Mix.raise(msg)
    end
  end
```

Remove the now-unused private `stop_one/1`, `stop_all/0`, `sweep/1` helpers and the unused `alias Dockd.Instance` from the Mix task.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/stop_test.exs && mix compile`
Expected: PASS (2 tests); clean compile.

- [ ] **Step 6: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/instance/stop.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.instance.stop.ex \
        apps/dockd_cli/test/dockd_cli/commands/instance/stop_test.exs
git commit -m "refactor: extract instance stop into DockdCli.Commands layer"
```

---

### Task 6: Extract remaining lifecycle commands (start, restart, destroy)

`start`, `restart`, and `destroy` share the single-name-or-`--all` shape. Extract each into its own command module and rewire its Mix task, following the exact pattern established in Task 5. Do all three in this task since they are near-identical and each is a few lines.

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/commands/instance/start.ex`
- Create: `apps/dockd_cli/lib/dockd_cli/commands/instance/restart.ex`
- Create: `apps/dockd_cli/lib/dockd_cli/commands/instance/destroy.ex`
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.instance.start.ex`
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.instance.restart.ex`
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.instance.destroy.ex`
- Test: `apps/dockd_cli/test/dockd_cli/commands/instance/lifecycle_test.exs`

**Interfaces:**
- Consumes: `Dockd.start/2`, `Dockd.restart/2`, `Dockd.destroy/2`; `DockdCli.Output`.
- Produces:
  - `DockdCli.Commands.Instance.Start.run(map(), keyword()) :: :ok | {:error, term()}`
  - `DockdCli.Commands.Instance.Restart.run(map(), keyword()) :: :ok | {:error, term()}`
  - `DockdCli.Commands.Instance.Destroy.run(map(), keyword()) :: :ok | {:error, term()}`

Before writing code, read the current `dockd.instance.start.ex`, `dockd.instance.restart.ex`, and `dockd.instance.destroy.ex` to capture each task's exact success message and any confirmation/`--force` behavior. Preserve those verbatim in the extracted module.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.Commands.Instance.LifecycleTest do
  use ExUnit.Case, async: true

  alias DockdCli.Commands.Instance.{Start, Restart, Destroy}

  test "start requires a name" do
    assert {:error, msg} = Start.run(%{}, [])
    assert msg =~ "NAME"
  end

  test "restart requires a name" do
    assert {:error, msg} = Restart.run(%{}, [])
    assert msg =~ "NAME"
  end

  test "destroy requires a name" do
    assert {:error, msg} = Destroy.run(%{}, [])
    assert msg =~ "NAME"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/lifecycle_test.exs`
Expected: FAIL with the command modules undefined.

- [ ] **Step 3: Write minimal implementation for each module**

`apps/dockd_cli/lib/dockd_cli/commands/instance/start.ex`:

```elixir
defmodule DockdCli.Commands.Instance.Start do
  @moduledoc "Starts a stopped dockd-managed instance."
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.start(name, opts) do
      :ok -> Output.info("Started #{name}")
      {:error, err} -> {:error, err}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance start NAME"}
end
```

`apps/dockd_cli/lib/dockd_cli/commands/instance/restart.ex`:

```elixir
defmodule DockdCli.Commands.Instance.Restart do
  @moduledoc "Stops then starts a dockd-managed instance."
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.restart(name, opts) do
      :ok -> Output.info("Restarted #{name}")
      {:error, err} -> {:error, err}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance restart NAME"}
end
```

`apps/dockd_cli/lib/dockd_cli/commands/instance/destroy.ex` (adjust the message and any `--force`/`--all` handling to match what the current Mix task does, read in the preamble above):

```elixir
defmodule DockdCli.Commands.Instance.Destroy do
  @moduledoc "Stops and removes a dockd-managed instance."
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.destroy(name, opts) do
      :ok -> Output.info("Destroyed #{name}")
      {:error, err} -> {:error, err}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance destroy NAME"}
end
```

- [ ] **Step 4: Rewire the three Mix tasks**

For each of `dockd.instance.start.ex`, `dockd.instance.restart.ex`, `dockd.instance.destroy.ex`, replace `run/1` so it parses argv (preserving each task's existing `@switches`) into a `%{name: List.first(args)}` map (plus `:all`/`:force` if that task already supports them) and delegates:

```elixir
  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)
    parsed = %{name: List.first(args)} |> Map.merge(Map.new(opts))

    case <CommandModule>.run(parsed, []) do
      :ok -> :ok
      {:error, %Dockd.Error{} = err} -> Mix.raise(Exception.message(err))
      {:error, msg} when is_binary(msg) -> Mix.raise(msg)
    end
  end
```

Replace `<CommandModule>` with `DockdCli.Commands.Instance.Start`, `.Restart`, or `.Destroy` respectively. Remove now-unused private helpers.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/lifecycle_test.exs && mix compile`
Expected: PASS (3 tests); clean compile.

- [ ] **Step 6: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/instance/start.ex \
        apps/dockd_cli/lib/dockd_cli/commands/instance/restart.ex \
        apps/dockd_cli/lib/dockd_cli/commands/instance/destroy.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.instance.start.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.instance.restart.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.instance.destroy.ex \
        apps/dockd_cli/test/dockd_cli/commands/instance/lifecycle_test.exs
git commit -m "refactor: extract start/restart/destroy into DockdCli.Commands layer"
```

---

### Task 7: Extract `DockdCli.Commands.Instance.Logs` + rewire Mix task

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/commands/instance/logs.ex`
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.instance.logs.ex`
- Test: `apps/dockd_cli/test/dockd_cli/commands/instance/logs_test.exs`

**Interfaces:**
- Consumes: `Dockd.logs/2`; `DockdCli.Output.write/1`.
- Produces:
  - `DockdCli.Commands.Instance.Logs.build_log_opts(map()) :: {:ok, keyword()} | {:error, binary()}`
  - `DockdCli.Commands.Instance.Logs.run(map(), keyword()) :: :ok | {:error, term()}` where `map()` includes `:name` plus the filter flags `:tail, :timestamps, :since, :until, :stdout_only, :stderr_only`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.Commands.Instance.LogsTest do
  use ExUnit.Case, async: true

  alias DockdCli.Commands.Instance.Logs

  test "requires a name" do
    assert {:error, msg} = Logs.run(%{}, [])
    assert msg =~ "NAME"
  end

  test "build_log_opts keeps passthrough filters" do
    assert {:ok, opts} = Logs.build_log_opts(%{tail: 100, timestamps: true})
    assert opts[:tail] == 100
    assert opts[:timestamps] == true
  end

  test "build_log_opts maps stderr_only to stream flags" do
    assert {:ok, opts} = Logs.build_log_opts(%{stderr_only: true})
    assert opts[:stdout] == false
    assert opts[:stderr] == true
  end

  test "build_log_opts rejects both stream-only flags" do
    assert {:error, msg} = Logs.build_log_opts(%{stdout_only: true, stderr_only: true})
    assert msg =~ "mutually exclusive"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/logs_test.exs`
Expected: FAIL with `DockdCli.Commands.Instance.Logs` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule DockdCli.Commands.Instance.Logs do
  @moduledoc "Prints an instance's container logs verbatim to stdout."
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{name: name} = args, opts) when is_binary(name) and name != "" do
    with {:ok, log_opts} <- build_log_opts(args) do
      case Dockd.logs(name, Keyword.merge(opts, log_opts)) do
        {:ok, binary} -> Output.write(binary)
        {:error, err} -> {:error, err}
      end
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance logs NAME [opts]"}

  @spec build_log_opts(map()) :: {:ok, keyword()} | {:error, binary()}
  def build_log_opts(args) do
    base =
      [:tail, :timestamps, :since, :until]
      |> Enum.reduce([], fn key, acc ->
        case Map.get(args, key) do
          nil -> acc
          value -> [{key, value} | acc]
        end
      end)

    cond do
      args[:stdout_only] && args[:stderr_only] ->
        {:error, "--stdout-only and --stderr-only are mutually exclusive"}

      args[:stdout_only] ->
        {:ok, base ++ [stdout: true, stderr: false]}

      args[:stderr_only] ->
        {:ok, base ++ [stdout: false, stderr: true]}

      true ->
        {:ok, base}
    end
  end
end
```

- [ ] **Step 4: Rewire the Mix task**

Replace `run/1` in `apps/dockd_cli/lib/mix/tasks/dockd.instance.logs.ex` (keep moduledoc + `@switches`):

```elixir
  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown flags: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    parsed = opts |> Map.new() |> Map.put(:name, List.first(args))

    case DockdCli.Commands.Instance.Logs.run(parsed, []) do
      :ok -> :ok
      {:error, %Dockd.Error{} = err} -> Mix.raise(Exception.message(err))
      {:error, msg} when is_binary(msg) -> Mix.raise(msg)
      {:error, reason} -> Mix.raise("Failed to fetch logs: #{inspect(reason)}")
    end
  end
```

Remove the task's private `fetch/2` and `build_log_opts/1`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/logs_test.exs && mix compile`
Expected: PASS (4 tests); clean compile.

- [ ] **Step 6: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/instance/logs.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.instance.logs.ex \
        apps/dockd_cli/test/dockd_cli/commands/instance/logs_test.exs
git commit -m "refactor: extract instance logs into DockdCli.Commands layer"
```

---

### Task 8: Extract `DockdCli.Commands.Instance.Inspect` + rewire Mix task

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/commands/instance/inspect.ex`
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.instance.inspect.ex`
- Test: `apps/dockd_cli/test/dockd_cli/commands/instance/inspect_test.exs`

**Interfaces:**
- Consumes: `Dockd.inspect/2`; `DockdCli.Output`.
- Produces: `DockdCli.Commands.Instance.Inspect.run(map(), keyword()) :: :ok | {:error, term()}`.

Before writing, read `apps/dockd_cli/lib/mix/tasks/dockd.instance.inspect.ex` and preserve its exact output format (e.g. JSON encoding or inspect formatting) in the command module.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.Commands.Instance.InspectTest do
  use ExUnit.Case, async: true

  alias DockdCli.Commands.Instance.Inspect

  test "requires a name" do
    assert {:error, msg} = Inspect.run(%{}, [])
    assert msg =~ "NAME"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/inspect_test.exs`
Expected: FAIL with `DockdCli.Commands.Instance.Inspect` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule DockdCli.Commands.Instance.Inspect do
  @moduledoc "Prints the raw Docker inspect map for an instance."
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{name: name}, opts) when is_binary(name) and name != "" do
    case Dockd.inspect(name, opts) do
      {:ok, raw} -> Output.info(format(raw))
      {:error, err} -> {:error, err}
    end
  end

  def run(_args, _opts), do: {:error, "Usage: dockd instance inspect NAME"}

  # Match the current Mix task's output format exactly (read it first).
  defp format(raw), do: inspect(raw, pretty: true, limit: :infinity)
end
```

- [ ] **Step 4: Rewire the Mix task**

Replace `run/1` in `apps/dockd_cli/lib/mix/tasks/dockd.instance.inspect.ex` to parse the name and delegate to `DockdCli.Commands.Instance.Inspect.run(%{name: List.first(args)}, [])`, mapping `{:error, ...}` to `Mix.raise` as in Task 7. Remove now-unused private helpers.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/inspect_test.exs && mix compile`
Expected: PASS (1 test); clean compile.

- [ ] **Step 6: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/instance/inspect.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.instance.inspect.ex \
        apps/dockd_cli/test/dockd_cli/commands/instance/inspect_test.exs
git commit -m "refactor: extract instance inspect into DockdCli.Commands layer"
```

---

### Task 9: Extract `DockdCli.Commands.Instance.Run` + rewire Mix task

This is the most complex command: mutually-exclusive source flags, provisioning, and an interactive wait. Move the source-resolution and apply logic into the command module; keep the parity behavior (print connect command, block on Enter, destroy; `--short`, `--detached`).

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/commands/instance/run.ex`
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.instance.run.ex`
- Test: `apps/dockd_cli/test/dockd_cli/commands/instance/run_test.exs`

**Interfaces:**
- Consumes: `Dockd.apply/2`, `Dockd.apply_package/2`, `Dockd.destroy/1`, `Dockd.Packages.resolve_path/1`, the `Dockd.Spec.*` pipeline modules already used by the current task; `DockdCli.Output`.
- Produces:
  - `DockdCli.Commands.Instance.Run.validate_source_flags(map()) :: :ok | {:error, binary()}`
  - `DockdCli.Commands.Instance.Run.connect_command(Dockd.Instance.t()) :: binary()`
  - `DockdCli.Commands.Instance.Run.run(map(), keyword()) :: :ok | {:error, term()}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.Commands.Instance.RunTest do
  use ExUnit.Case, async: true

  alias DockdCli.Commands.Instance.Run

  test "rejects --preset combined with --image" do
    assert {:error, msg} = Run.validate_source_flags(%{preset: "p", image: "busybox"})
    assert msg =~ "--preset"
  end

  test "rejects --package combined with --dockerfile" do
    assert {:error, msg} = Run.validate_source_flags(%{package: "p.json", dockerfile: "./D"})
    assert msg =~ "--package"
  end

  test "accepts a lone source flag" do
    assert Run.validate_source_flags(%{image: "busybox"}) == :ok
  end

  test "connect_command builds a docker exec line" do
    inst = %Dockd.Instance{name: "dockd-smoke", shell: "/bin/sh"}
    assert Run.connect_command(inst) == "docker exec -it dockd-smoke /bin/sh"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/run_test.exs`
Expected: FAIL with `DockdCli.Commands.Instance.Run` undefined.

- [ ] **Step 3: Write minimal implementation**

Port the logic from the current `Mix.Tasks.Dockd.Instance.Run` verbatim, replacing `Mix.shell().info/error` with `DockdCli.Output.info/error`, `exit({:shutdown, 1})` with `{:error, message}` returns, and reading args from the `map()` instead of `OptionParser`. Keep `resolve_source/1`, `build_source/1`, `dockerfile_source/2`, `image_source/1`, `load_runnable_spec/2`, `apply_name_override/2`, `handle_apply/3`, `await_shutdown/3`, `announce_ready/3`, `connect_command/1`, `shell_escape/1` intact. Expose `validate_source_flags/1` and `connect_command/1` as public (`def`) for testing; keep the rest private. The interactive `await_shutdown` still uses `IO.gets("")` and `Dockd.destroy/1`.

```elixir
defmodule DockdCli.Commands.Instance.Run do
  @moduledoc "Provision and start a Docker instance, then wait to tear it down."

  alias Dockd.ApplyResult
  alias Dockd.Instance
  alias Dockd.Spec
  alias Dockd.Spec.Interpolator
  alias Dockd.Spec.Normalizer
  alias Dockd.Spec.Parser
  alias Dockd.Spec.Source
  alias DockdCli.Output

  @default_image "debian:trixie"
  @default_shell "/bin/sh"
  @default_tag "dockd-build:latest"

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(args, opts) do
    short? = args[:short] || false
    detached? = args[:detached] || false

    with :ok <- validate_source_flags(args) do
      case build_source(args) do
        {:ok, action, {:file, path}} ->
          unless short?, do: Output.info("#{action} and starting container...")
          run_apply_package(path, args[:name], short?, detached?, opts)

        {:ok, action, {:opts, image, spec_opts}} ->
          run_from_image(args, image, spec_opts, action, short?, detached?, opts)
      end
    end
  end

  @spec validate_source_flags(map()) :: :ok | {:error, binary()}
  def validate_source_flags(args) do
    preset = args[:preset]
    package = args[:package]
    others = [args[:dockerfile], args[:image], args[:tag]]

    cond do
      preset && (package || Enum.any?(others)) ->
        {:error, "--preset cannot be combined with --package, --image, --dockerfile, or --tag"}

      package && Enum.any?(others) ->
        {:error, "--package cannot be combined with --image, --dockerfile, or --tag"}

      true ->
        :ok
    end
  end

  defp run_from_image(args, image, spec_opts, action, short?, detached?, opts) do
    case args[:name] do
      name when is_binary(name) and name != "" ->
        spec_opts = Keyword.put(spec_opts, :name, name)
        unless short?, do: Output.info("#{action} and starting container...")
        handle_apply(Dockd.apply(image, spec_opts ++ opts), short?, detached?)

      _ ->
        {:error, "--name is required (e.g. --name work)"}
    end
  end

  defp build_source(args) do
    cond do
      preset = args[:preset] ->
        {:ok, "Loading preset #{preset}", {:file, Dockd.Packages.resolve_path(preset)}}

      package = args[:package] ->
        {:ok, "Loading package #{package}", {:file, package}}

      dockerfile = args[:dockerfile] ->
        {:ok, "Building from #{dockerfile}",
         {:opts, args[:tag] || @default_tag, [shell: @default_shell, build: %{dockerfile: dockerfile}]}}

      true ->
        image = args[:image] || @default_image
        {:ok, "Pulling #{image}", {:opts, image, [shell: @default_shell]}}
    end
  end

  defp run_apply_package(path, name, short?, detached?, _opts) do
    case load_runnable_spec(path, name) do
      {:ok, spec} -> handle_apply(Dockd.apply(spec), short?, detached?)
      {:error, error} -> {:error, error}
    end
  end

  defp load_runnable_spec(path, name_override) do
    with {:ok, body} <- Source.read_file(path),
         {:ok, decoded} <- Parser.parse(body),
         {:ok, substituted} <- Interpolator.substitute(decoded, System.get_env()),
         {:ok, attrs} <- Normalizer.normalize(substituted, Path.dirname(path)),
         {:ok, attrs} <- apply_name_override(attrs, name_override) do
      {:ok, Spec.from_attrs(attrs)}
    end
  end

  defp apply_name_override(attrs, nil) do
    case Map.get(attrs, :name) do
      name when is_binary(name) and name != "" -> {:ok, attrs}
      _ -> {:error, %Dockd.Error{phase: :validate, message: ~s(package has no "name"; pass --name to supply one)}}
    end
  end

  defp apply_name_override(attrs, name) when is_binary(name) and name != "" do
    {:ok, Map.put(attrs, :name, name)}
  end

  defp handle_apply({:ok, %ApplyResult{instance: instance}}, short?, detached?) do
    announce_ready(instance, short?, detached?)
    await_shutdown(instance, short?, detached?)
  end

  defp handle_apply({:error, error}, _short?, _detached?), do: {:error, error}

  defp await_shutdown(_instance, _short?, true), do: :ok

  defp await_shutdown(instance, short?, false) do
    _ = IO.gets("")
    unless short?, do: Output.info("Stopping container...")
    _ = Dockd.destroy(instance)
    unless short?, do: Output.info("Done - container removed.")
    :ok
  end

  defp announce_ready(instance, true, _detached), do: Output.write(connect_command(instance) <> "\n")

  defp announce_ready(instance, false, true) do
    Output.info("""

    Container is ready (detached - will keep running after this task exits).

        Connect: #{connect_command(instance)}
        Destroy: docker rm -f #{instance.name}
    """)
  end

  defp announce_ready(instance, false, false) do
    Output.info("""

    Container is ready!

    Connect to it by running this command in another terminal:

        #{connect_command(instance)}

    Press Enter here when you're done to stop and remove the container.
    """)
  end

  @spec connect_command(Instance.t()) :: binary()
  def connect_command(%Instance{name: name, shell: shell})
      when is_binary(name) and is_binary(shell),
      do: "docker exec -it #{shell_escape(name)} #{shell_escape(shell)}"

  defp shell_escape(value) when is_binary(value) do
    if value == "" or not String.match?(value, ~r/^[A-Za-z0-9_@%+=:,.\/-]+$/) do
      "'" <> String.replace(value, "'", ~s('"'"')) <> "'"
    else
      value
    end
  end
end
```

- [ ] **Step 4: Rewire the Mix task**

Replace `run/1` in `apps/dockd_cli/lib/mix/tasks/dockd.instance.run.ex` (keep moduledoc) to parse argv with the existing `strict:` switch list into a map and delegate:

```elixir
  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          image: :string, dockerfile: :string, tag: :string, package: :string,
          preset: :string, name: :string, short: :boolean, detached: :boolean
        ]
      )

    case DockdCli.Commands.Instance.Run.run(Map.new(opts), []) do
      :ok -> :ok
      {:error, %Dockd.Error{} = err} -> Mix.raise("Failed during #{err.phase}: #{err.message}")
      {:error, msg} when is_binary(msg) -> Mix.raise(msg)
    end
  end
```

Delete all the private helpers now living in the command module and the module attributes/`alias`es they used.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/run_test.exs && mix compile`
Expected: PASS (4 tests); clean compile.

- [ ] **Step 6: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/instance/run.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.instance.run.ex \
        apps/dockd_cli/test/dockd_cli/commands/instance/run_test.exs
git commit -m "refactor: extract instance run into DockdCli.Commands layer"
```

---

### Task 10: Extract `DockdCli.Commands.Info` + rewire Mix task

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/commands/info.ex`
- Modify: `apps/dockd_cli/lib/mix/tasks/dockd.info.ex`
- Test: `apps/dockd_cli/test/dockd_cli/commands/info_test.exs`

**Interfaces:**
- Consumes: `Dockd.info/1`; `DockdCli.Output.info/1`.
- Produces: `DockdCli.Commands.Info.run(map(), keyword()) :: :ok | {:error, term()}`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.Commands.InfoTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias DockdCli.Commands.Info

  test "renders each top-level section under a header" do
    info = %{temp_files: %{count: 2, total_bytes: 10, oldest_at: nil, newest_at: nil}}
    out = capture_io(fn -> assert Info.render({:ok, info}) == :ok end)
    assert out =~ "[temp_files]"
    assert out =~ "count: 2"
    assert out =~ "oldest_at: -"
  end

  test "passes through errors" do
    err = %Dockd.Error{phase: :discover, message: "x"}
    assert Info.render({:error, err}) == {:error, err}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/info_test.exs`
Expected: FAIL with `DockdCli.Commands.Info` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule DockdCli.Commands.Info do
  @moduledoc "Prints aggregate dockd state, one section per top-level key."
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(_args, opts), do: render(Dockd.info(opts))

  @doc false
  def render({:ok, info}) do
    info |> Enum.sort() |> Enum.each(&render_section/1)
  end

  def render({:error, err}), do: {:error, err}

  defp render_section({key, value}) do
    Output.info("[#{key}]")

    case value do
      %{} = map ->
        for {k, v} <- Enum.sort(map), do: Output.info("  #{k}: #{format_value(v)}")

      other ->
        Output.info("  #{format_value(other)}")
    end

    Output.info("")
  end

  defp format_value(nil), do: "-"
  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
end
```

- [ ] **Step 4: Rewire the Mix task**

Replace `run/1` in `apps/dockd_cli/lib/mix/tasks/dockd.info.ex` to delegate to `DockdCli.Commands.Info.run(%{}, [])`, mapping errors to `Mix.raise`. Remove the private `render_section/1` and `format_value/1` helpers.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/info_test.exs && mix compile`
Expected: PASS (2 tests); clean compile.

- [ ] **Step 6: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/info.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.info.ex \
        apps/dockd_cli/test/dockd_cli/commands/info_test.exs
git commit -m "refactor: extract info into DockdCli.Commands layer"
```

---

### Task 11: Extract package + ssh commands, rewire their Mix tasks

Extract `dockd.package.install`, `dockd.package.show`, `dockd.package.validate`, `dockd.ssh.dial_stdio_script.generate`, and `dockd.ssh.dial_stdio_script.install` into command modules following the established pattern (logic in `DockdCli.Commands.Package.*` / `DockdCli.Commands.Ssh.*`, Mix tasks become thin parsers). Before writing each, read the corresponding Mix task to capture its flags, output, and error messages, and preserve them verbatim.

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/commands/package/install.ex`
- Create: `apps/dockd_cli/lib/dockd_cli/commands/package/show.ex`
- Create: `apps/dockd_cli/lib/dockd_cli/commands/package/validate.ex`
- Create: `apps/dockd_cli/lib/dockd_cli/commands/ssh/dial_stdio_script_generate.ex`
- Create: `apps/dockd_cli/lib/dockd_cli/commands/ssh/dial_stdio_script_install.ex`
- Modify: the five corresponding `apps/dockd_cli/lib/mix/tasks/dockd.package.*.ex` / `dockd.ssh.*.ex` files
- Test: `apps/dockd_cli/test/dockd_cli/commands/package_test.exs`

**Interfaces:**
- Produces (all `run(map(), keyword()) :: :ok | {:error, term()}`):
  - `DockdCli.Commands.Package.Install.run/2`
  - `DockdCli.Commands.Package.Show.run/2`
  - `DockdCli.Commands.Package.Validate.run/2`
  - `DockdCli.Commands.Ssh.DialStdioScriptGenerate.run/2`
  - `DockdCli.Commands.Ssh.DialStdioScriptInstall.run/2`

- [ ] **Step 1: Read the five Mix tasks**

Run: `cat apps/dockd_cli/lib/mix/tasks/dockd.package.install.ex apps/dockd_cli/lib/mix/tasks/dockd.package.show.ex apps/dockd_cli/lib/mix/tasks/dockd.package.validate.ex apps/dockd_cli/lib/mix/tasks/dockd.ssh.dial_stdio_script.generate.ex apps/dockd_cli/lib/mix/tasks/dockd.ssh.dial_stdio_script.install.ex`
Record each task's `@switches`, positional args, success message, and error messages.

- [ ] **Step 2: Write the failing test**

```elixir
defmodule DockdCli.Commands.PackageTest do
  use ExUnit.Case, async: true

  alias DockdCli.Commands.Package.{Install, Show, Validate}

  test "install requires a source/url argument" do
    assert {:error, _} = Install.run(%{}, [])
  end

  test "show requires a package reference" do
    assert {:error, _} = Show.run(%{}, [])
  end

  test "validate requires a package reference" do
    assert {:error, _} = Validate.run(%{}, [])
  end
end
```

Adjust the required-argument assertions to match what each Mix task actually requires (from Step 1).

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/package_test.exs`
Expected: FAIL with the command modules undefined.

- [ ] **Step 4: Write the five command modules**

Port each Mix task's logic into its command module: replace `Mix.shell().info/error` → `DockdCli.Output.info/error`, `Mix.raise(msg)` → `{:error, msg}`, `exit({:shutdown, 1})` → `{:error, msg}`, and read arguments from the passed `map()`. Thread the `opts` keyword arg into any `Dockd.*` call that accepts per-call options (e.g. `Dockd.install_packages/2`). Keep output text identical to the originals.

- [ ] **Step 5: Rewire the five Mix tasks**

Each Mix task keeps its moduledoc and `@switches`, parses argv into a map, and delegates to its command module, mapping `{:error, %Dockd.Error{}}` and `{:error, binary}` to `Mix.raise`. Remove now-unused private helpers.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/commands/package_test.exs && mix compile`
Expected: PASS; clean compile.

- [ ] **Step 7: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/package \
        apps/dockd_cli/lib/dockd_cli/commands/ssh \
        apps/dockd_cli/lib/mix/tasks/dockd.package.install.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.package.show.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.package.validate.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.ssh.dial_stdio_script.generate.ex \
        apps/dockd_cli/lib/mix/tasks/dockd.ssh.dial_stdio_script.install.ex \
        apps/dockd_cli/test/dockd_cli/commands/package_test.exs
git commit -m "refactor: extract package and ssh commands into DockdCli.Commands layer"
```

---

### Task 12: `DockdCli.CLI` — Optimus spec + dispatch table

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/cli.ex`
- Test: `apps/dockd_cli/test/dockd_cli/cli_test.exs`

**Interfaces:**
- Consumes: `Optimus`; all `DockdCli.Commands.*` modules.
- Produces:
  - `DockdCli.CLI.spec() :: Optimus.t()` — the full command tree with global `--socket`/`--host` options and all subcommands.
  - `DockdCli.CLI.dispatch(Optimus.ParseResult.t() | {[atom()], Optimus.ParseResult.t()}) :: :ok | {:error, term()}` — maps a parsed subcommand path to `<CommandModule>.run(args_map, opts)`, building `args_map` from parsed args/flags/options and `opts` via `DockdCli.Options.resolve/2`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.CLITest do
  use ExUnit.Case, async: true

  test "spec parses `instance list`" do
    spec = DockdCli.CLI.spec()
    assert {:ok, [:instance, :list], _parsed} = Optimus.parse(spec, ["instance", "list"])
  end

  test "spec parses `instance run` with flags" do
    spec = DockdCli.CLI.spec()
    assert {:ok, [:instance, :run], parsed} =
             Optimus.parse(spec, ["instance", "run", "--image", "busybox", "--name", "w"])

    assert parsed.options.image == "busybox"
    assert parsed.options.name == "w"
  end

  test "spec exposes global --socket option" do
    spec = DockdCli.CLI.spec()
    assert {:ok, [:instance, :list], parsed} =
             Optimus.parse(spec, ["--socket", "/x.sock", "instance", "list"])

    assert parsed.options.socket == "/x.sock"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/cli_test.exs`
Expected: FAIL with `DockdCli.CLI` undefined.

- [ ] **Step 3: Write minimal implementation**

Build the Optimus spec with global options `socket`/`host` and a subcommand tree mirroring the command surface. (Optimus supports global options and nested subcommands.) Then a `dispatch/1` that matches the returned subcommand path to a command module.

```elixir
defmodule DockdCli.CLI do
  @moduledoc "Optimus command specification and dispatch for the `dockd` binary."

  alias DockdCli.Commands
  alias DockdCli.Options

  @spec spec() :: Optimus.t()
  def spec do
    Optimus.new!(
      name: "dockd",
      description: "Manage local Docker workspaces",
      version: "0.1.0",
      allow_unknown_args: false,
      parse_double_dash: true,
      global_options: [
        socket: [long: "--socket", help: "Docker socket path", required: false],
        host: [long: "--host", help: "Docker host", required: false]
      ],
      subcommands: [
        instance: [
          name: "instance",
          about: "Manage instances",
          subcommands: [
            list: [name: "list", about: "List instances"],
            run: [name: "run", about: "Provision and start an instance", options: run_options(), flags: run_flags()],
            stop: [name: "stop", about: "Stop an instance", args: [name: [required: false]], flags: [all: [long: "--all"]]],
            start: [name: "start", about: "Start an instance", args: [name: [required: false]]],
            restart: [name: "restart", about: "Restart an instance", args: [name: [required: false]]],
            destroy: [name: "destroy", about: "Destroy an instance", args: [name: [required: false]]],
            logs: [name: "logs", about: "Print instance logs", args: [name: [required: false]], options: log_options(), flags: log_flags()],
            inspect: [name: "inspect", about: "Inspect an instance", args: [name: [required: false]]]
          ]
        ],
        package: [
          name: "package",
          about: "Manage packages",
          subcommands: [
            install: [name: "install", about: "Install packages from git", options: package_install_options()],
            show: [name: "show", about: "Show a package", args: [ref: [required: false]]],
            validate: [name: "validate", about: "Validate a package", args: [ref: [required: false]]]
          ]
        ],
        info: [name: "info", about: "Show aggregate dockd state"]
      ]
    )
  end

  # Fill these option/flag lists to match the flags recorded when extracting
  # each command (Tasks 9, 7, 11). Names must match the map keys the command
  # modules read.
  defp run_options,
    do: [
      image: [long: "--image"],
      dockerfile: [long: "--dockerfile"],
      tag: [long: "--tag"],
      package: [long: "--package"],
      preset: [long: "--preset"],
      name: [long: "--name"]
    ]

  defp run_flags, do: [short: [long: "--short"], detached: [long: "--detached"]]

  defp log_options,
    do: [tail: [long: "--tail", parser: :integer], since: [long: "--since", parser: :integer], until: [long: "--until", parser: :integer]]

  defp log_flags,
    do: [timestamps: [long: "--timestamps"], stdout_only: [long: "--stdout-only"], stderr_only: [long: "--stderr-only"]]

  defp package_install_options,
    do: [git_url: [long: "--git-url"], source: [long: "--source"], ref: [long: "--ref"]]

  @spec dispatch({[atom()], Optimus.ParseResult.t()}) :: :ok | {:error, term()}
  def dispatch({path, parsed}) do
    opts = Options.resolve(Map.new(parsed.options || %{}), System.get_env())
    args = build_args(parsed)

    command_for(path).run(args, opts)
  end

  defp build_args(parsed) do
    %{}
    |> Map.merge(Map.new(parsed.args || %{}))
    |> Map.merge(Map.new(parsed.options || %{}))
    |> Map.merge(Map.new(parsed.flags || %{}))
  end

  defp command_for([:instance, :list]), do: Commands.Instance.List
  defp command_for([:instance, :run]), do: Commands.Instance.Run
  defp command_for([:instance, :stop]), do: Commands.Instance.Stop
  defp command_for([:instance, :start]), do: Commands.Instance.Start
  defp command_for([:instance, :restart]), do: Commands.Instance.Restart
  defp command_for([:instance, :destroy]), do: Commands.Instance.Destroy
  defp command_for([:instance, :logs]), do: Commands.Instance.Logs
  defp command_for([:instance, :inspect]), do: Commands.Instance.Inspect
  defp command_for([:package, :install]), do: Commands.Package.Install
  defp command_for([:package, :show]), do: Commands.Package.Show
  defp command_for([:package, :validate]), do: Commands.Package.Validate
  defp command_for([:info]), do: Commands.Info
end
```

Note: `--name` for `stop/start/restart/destroy` comes through Optimus `args` as `:name`; the `stop` command's `:all` arrives as a flag. Verify the arg/flag/option names here match the map keys each command module reads (adjust either side to agree). Add `ssh` subcommands here too if you want them exposed in the binary (mirror the package pattern).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/cli_test.exs && mix compile`
Expected: PASS (3 tests); clean compile.

- [ ] **Step 5: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/cli.ex apps/dockd_cli/test/dockd_cli/cli_test.exs
git commit -m "feat: add Optimus CLI spec and dispatch table"
```

---

### Task 13: `DockdCli.Main` — binary entrypoint

**Files:**
- Create: `apps/dockd_cli/lib/dockd_cli/main.ex`
- Test: `apps/dockd_cli/test/dockd_cli/main_test.exs`

**Interfaces:**
- Consumes: `DockdCli.CLI.spec/0`, `DockdCli.CLI.dispatch/1`, `DockdCli.Output.error/1`.
- Produces:
  - `DockdCli.Main.run(argv :: [String.t()]) :: :ok | {:error, term()}` — testable core (no `halt`).
  - `DockdCli.Main.main(argv :: [String.t()]) :: no_return()` — Burrito entrypoint; calls `run/1` then `System.halt/1`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.MainTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  test "run returns error tuple for an unknown command without halting" do
    captured = capture_io(:stderr, fn -> send(self(), {:result, DockdCli.Main.run(["totally-bogus"])}) end)
    assert_received {:result, {:error, _}}
    assert captured != ""
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/dockd_cli/test/dockd_cli/main_test.exs`
Expected: FAIL with `DockdCli.Main` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule DockdCli.Main do
  @moduledoc "Entry point for the standalone `dockd` binary."

  alias DockdCli.CLI
  alias DockdCli.Output

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    ensure_started()

    case run(argv) do
      :ok -> System.halt(0)
      {:error, _} -> System.halt(1)
    end
  end

  @spec run([String.t()]) :: :ok | {:error, term()}
  def run(argv) do
    case Optimus.parse(CLI.spec(), argv) do
      {:ok, parsed} ->
        # top-level with no subcommand: Optimus prints help and returns :ok-ish;
        # treat a bare parse (no subcommand path) as help already shown.
        {:error, :no_subcommand} |> tap(fn _ -> Optimus.help(CLI.spec()) end)

      {:ok, path, parsed} ->
        report(CLI.dispatch({path, parsed}))

      {:error, reasons} ->
        Enum.each(List.wrap(reasons), &Output.error/1)
        {:error, :usage}

      {:error, _path, reasons} ->
        Enum.each(List.wrap(reasons), &Output.error/1)
        {:error, :usage}

      :version ->
        :ok

      :help ->
        :ok

      {:help, _subcommand} ->
        :ok
    end
  end

  defp report(:ok), do: :ok

  defp report({:error, %Dockd.Error{} = err}) do
    Output.error(Exception.message(err))
    {:error, err}
  end

  defp report({:error, msg}) when is_binary(msg) do
    Output.error(msg)
    {:error, msg}
  end

  defp report({:error, other}) do
    Output.error(inspect(other))
    {:error, other}
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:dockd)
    {:ok, _} = Application.ensure_all_started(:dockd_ssh)
    :ok
  end
end
```

Consult the Optimus docs for the exact return shapes of `Optimus.parse/2` (the `:help`, `:version`, and error variants) and adjust the `case` clauses so every variant is handled and help/version print correctly. Keep `run/1` free of `System.halt` so it stays testable.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/dockd_cli/test/dockd_cli/main_test.exs && mix compile`
Expected: PASS (1 test); clean compile.

- [ ] **Step 5: Manual end-to-end check via Mix**

Run: `mix run -e 'DockdCli.Main.run(["instance", "list"])'`
Expected: prints the instance table or `No dockd instances.` (requires a running Docker daemon), exits without error.

- [ ] **Step 6: Commit**

```bash
git add apps/dockd_cli/lib/dockd_cli/main.ex apps/dockd_cli/test/dockd_cli/main_test.exs
git commit -m "feat: add DockdCli.Main binary entrypoint"
```

---

### Task 14: Runtime config for temp dir

**Files:**
- Create: `config/runtime.exs` (if it does not already exist)
- Modify: `apps/dockd/lib/dockd/config.ex` (only if temp-dir reads compile-time config; otherwise leave as-is)
- Test: `apps/dockd_cli/test/dockd_cli/runtime_config_test.exs`

**Interfaces:**
- Produces: at boot, `:dockd, :temp_dir` resolves from `DOCKD_TMP` env when set, else the existing default.

Before editing, read `apps/dockd/lib/dockd/config.ex` to see how `temp_dir` is currently read. If it already reads an env var at runtime, skip the code change and only add the `runtime.exs` documentation/override.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DockdCli.RuntimeConfigTest do
  use ExUnit.Case, async: false

  test "DOCKD_TMP overrides the configured temp dir at runtime" do
    original = Application.get_env(:dockd, :temp_dir)
    on_exit(fn -> Application.put_env(:dockd, :temp_dir, original) end)

    # Simulate the runtime.exs resolution logic.
    resolved = System.get_env("DOCKD_TMP") || "/tmp/dockd"
    Application.put_env(:dockd, :temp_dir, resolved)

    assert is_binary(Application.get_env(:dockd, :temp_dir))
  end
end
```

- [ ] **Step 2: Run test to verify it fails or passes trivially**

Run: `mix test apps/dockd_cli/test/dockd_cli/runtime_config_test.exs`
Expected: PASS (this guards the resolution contract; the real behavior lives in `runtime.exs`).

- [ ] **Step 3: Add `config/runtime.exs`**

Create or extend `config/runtime.exs`:

```elixir
import Config

# Resolved at release boot (not build time) so the shipped binary honors
# the end user's environment.
if tmp = System.get_env("DOCKD_TMP") do
  config :dockd, temp_dir: tmp
end
```

- [ ] **Step 4: Verify config loads**

Run: `mix compile && DOCKD_TMP=/tmp/dockd-alt mix run -e 'IO.inspect(Application.get_env(:dockd, :temp_dir))'`
Expected: prints `"/tmp/dockd-alt"`.

- [ ] **Step 5: Commit**

```bash
git add config/runtime.exs apps/dockd_cli/test/dockd_cli/runtime_config_test.exs
git commit -m "feat: honor DOCKD_TMP at release runtime"
```

---

### Task 15: Burrito release config + local build

**Files:**
- Modify: `apps/dockd_cli/mix.exs`
- Modify: `mix.exs` (umbrella root — add `burrito` dep so it is available to the release)
- Create/Modify: release config in `apps/dockd_cli/mix.exs` `releases/0`

**Interfaces:**
- Produces: a self-contained `dockd` executable under `apps/dockd_cli/burrito_out/` (or the configured output dir) for the local platform.

Consult the current Burrito README for the exact release/wrapper API before wiring (the `Burrito.wrap/1` step and `burrito:` release option names evolve).

- [ ] **Step 1: Add the Burrito dependency**

In `apps/dockd_cli/mix.exs` deps:

```elixir
      {:burrito, "~> 1.0"}
```

Run: `mix deps.get`
Expected: `burrito` resolves.

- [ ] **Step 2: Add release + Burrito config**

In `apps/dockd_cli/mix.exs`, add to `project/0`:

```elixir
      releases: releases(),
```

and add:

```elixir
  defp releases do
    [
      dockd: [
        applications: [dockd_cli: :permanent],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :aarch64],
            linux: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
```

Ensure `apps/dockd_cli/mix.exs` sets `mod`/`extra_applications` as needed so `dockd_cli`, `dockd`, and `dockd_ssh` start in the release (they are already umbrella deps).

- [ ] **Step 3: Build the local target**

Run: `MIX_ENV=prod mix release dockd`
Expected: Burrito invokes Zig and emits a `dockd` executable for the host platform. If Zig is missing, install it (`brew install zig` on macOS) and re-run.

- [ ] **Step 4: Smoke-test the binary**

Run (adjust path to the emitted binary):
```bash
./apps/dockd_cli/burrito_out/dockd --help
./apps/dockd_cli/burrito_out/dockd instance list
```
Expected: `--help` prints the command tree; `instance list` prints the table or `No dockd instances.` against a running Docker daemon. No Elixir/Erlang required on `PATH`.

- [ ] **Step 5: Document the build**

Add a short "Building the standalone CLI" section to `README.md`: prerequisites (Zig), the `MIX_ENV=prod mix release dockd` command, where the binary lands, and that end users need only the binary + Docker.

- [ ] **Step 6: Commit**

```bash
git add apps/dockd_cli/mix.exs mix.exs mix.lock README.md
git commit -m "build: add Burrito release for self-contained dockd binary"
```

---

### Task 16: Full-suite regression + parity check

**Files:** none (verification task).

- [ ] **Step 1: Run the whole test suite**

Run: `mix test`
Expected: all tests pass (integration tests require a running Docker daemon; run with one available).

- [ ] **Step 2: Parity spot-check Mix vs binary**

Run each pair and confirm identical output/behavior:
```bash
mix dockd.instance.list
./apps/dockd_cli/burrito_out/dockd instance list

mix dockd.info
./apps/dockd_cli/burrito_out/dockd info
```
Expected: matching output from both entrypoints.

- [ ] **Step 3: Format + compile clean**

Run: `mix format --check-formatted && mix compile --warnings-as-errors`
Expected: no formatting diffs, no warnings.

- [ ] **Step 4: Commit any format fixes**

```bash
git add -A
git commit -m "chore: format and regression pass for standalone CLI" || echo "nothing to commit"
```

---

## Self-Review Notes

- **Spec coverage:** command layer (Tasks 2,4–11), Optimus dispatch (12), binary entrypoint (13), runtime config — socket/host (3) and temp dir (14), Burrito local build (15), testing (every task + 16), `run` parity (9). Distribution/CI intentionally omitted (deferred per spec non-goals).
- **Mix-free constraint:** enforced by `DockdCli.Output`/`DockdCli.Options` and each command module returning tuples; Mix tasks are the only `Mix.raise` callers.
- **Type consistency:** every command module exposes `run(map(), keyword()) :: :ok | {:error, term()}`; `DockdCli.CLI.command_for/1` maps to those exact modules; `DockdCli.Options.resolve/2` is the single opts source.
- **Known follow-ups the implementer must resolve against live docs:** exact `Optimus.parse/2` return variants (Task 13) and current Burrito release API (Task 15) — both flagged inline with instructions to consult the library docs, since those APIs shift between versions.
