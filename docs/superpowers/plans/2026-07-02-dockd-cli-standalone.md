# Standalone `dockd` CLI Implementation Plan (Lean v1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a self-contained `dockd` executable (via Burrito + Optimus) that mirrors the everyday `mix dockd.*` commands and runs on macOS/Linux with no Elixir/Erlang/Mix installed.

**Architecture:** Extract the logic in `Mix.Tasks.Dockd.*` into a new, Mix-free command layer (`DockdCli.Commands.*`) that writes via `DockdCli.Output` and returns `:ok | {:error, term}`. A single Optimus entrypoint (`DockdCli.Main`) parses argv and dispatches. The release is bundled into one executable with Burrito.

**Tech Stack:** Elixir umbrella, `optimus` (CLI parsing), `burrito` (self-contained release + Zig), the `Dockd` public API, `docker` HTTP client.

## Scope decisions (lean v1)

- **Existing Mix tasks are left untouched and unused.** Command modules are new code; the binary is the only consumer. `mix dockd.*` keeps working in dev via its current code. Deduplication is a deferred follow-up. *(Reversible; nothing deleted.)*
- **Connection options are global flags with env fallback.** `--socket`/`--host` flags are the primary interface (discoverable via `--help`); `DOCKER_SOCKET`/`DOCKER_HOST` env vars are honored as fallback. Precedence: **flag > env > default**. This mirrors the Docker CLI's own `--host` + `DOCKER_HOST` convention — non-secret config belongs in explicit flags, not hidden env vars.
- **No `ssh` subcommands in v1.** The `dockd.ssh.*` tasks are narrow/internal; deferred.
- Surface mirrored: `instance list|run|stop|start|restart|destroy|logs|inspect`, `package install|show|validate`, `info`.

## Global Constraints

- Target platforms: macOS (aarch64 primary) + Linux (x86_64). No Windows.
- End users install only the binary; a running Docker daemon is the only runtime prerequisite.
- `DockdCli.Commands.*`, `DockdCli.Output`, `DockdCli.Options` MUST NOT call any `Mix.*` function.
- Every command module: `run(map(), keyword()) :: :ok | {:error, term()}`. Only `DockdCli.Main` calls `System.halt/1`.
- Flag names/behavior/output text mirror the existing tasks exactly (port verbatim).
- Elixir `~> 1.17`. TDD: failing test first; commit per green task.
- **Two library APIs must be verified against the installed version before coding, not assumed:** `Optimus.parse/2` return variants (Task 7) and Burrito's `releases`/`burrito:` config keys (Task 8). The plan's code for these is a starting point flagged inline.

---

### Task 1: Add `optimus` dependency

**Files:** Modify `apps/dockd_cli/mix.exs`

**Interfaces:** Produces `Optimus` available to `apps/dockd_cli`.

- [ ] **Step 1:** In `apps/dockd_cli/mix.exs`, set `defp deps`:

```elixir
  defp deps do
    [
      {:dockd, in_umbrella: true},
      {:dockd_ssh, in_umbrella: true},
      {:optimus, "~> 0.5"}
    ]
  end
```

- [ ] **Step 2:** Run: `mix deps.get && mix compile` — Expected: clean compile; `optimus` resolves.
- [ ] **Step 3:** Commit:

```bash
git add apps/dockd_cli/mix.exs mix.lock
git commit -m "build: add optimus dependency to dockd_cli"
```

---

### Task 2: `DockdCli.Output` + `DockdCli.Options`

**Files:**
- Create `apps/dockd_cli/lib/dockd_cli/output.ex`
- Create `apps/dockd_cli/lib/dockd_cli/options.ex`
- Test `apps/dockd_cli/test/dockd_cli/output_test.exs`
- Test `apps/dockd_cli/test/dockd_cli/options_test.exs`

**Interfaces:**
- `DockdCli.Output.info(iodata) :: :ok` (stdout line), `error(iodata) :: :ok` (stderr line), `write(iodata) :: :ok` (raw stdout), `table([tuple], tuple) :: :ok` (padded table; header + rows same arity).
- `DockdCli.Options.resolve(flags :: map(), env :: map()) :: keyword()` — `:socket` from `--socket` flag else `DOCKER_SOCKET`; `:host` from `--host` flag else `DOCKER_HOST`. Precedence flag > env > absent; omit blank values.

- [ ] **Step 1: Failing tests**

`output_test.exs`:

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
    assert capture_io(:stderr, fn -> assert Output.error("boom") == :ok end) == "boom\n"
  end

  test "table pads columns and prints header first" do
    out = capture_io(fn -> Output.table([{"a", "1"}, {"bb", "22"}], {"NAME", "N"}) end)
    assert out == "NAME  N\na     1\nbb    22\n"
  end
end
```

`options_test.exs`:

```elixir
defmodule DockdCli.OptionsTest do
  use ExUnit.Case, async: true
  alias DockdCli.Options

  test "empty when nothing set" do
    assert Options.resolve(%{}, %{}) == []
  end

  test "reads socket and host from env" do
    opts = Options.resolve(%{}, %{"DOCKER_SOCKET" => "/run/d.sock", "DOCKER_HOST" => "tcp://x:2375"})
    assert opts[:socket] == "/run/d.sock"
    assert opts[:host] == "tcp://x:2375"
  end

  test "flag overrides env" do
    opts = Options.resolve(%{socket: "/from/flag.sock"}, %{"DOCKER_SOCKET" => "/from/env.sock"})
    assert opts[:socket] == "/from/flag.sock"
  end

  test "ignores blank values" do
    assert Options.resolve(%{socket: nil, host: ""}, %{"DOCKER_SOCKET" => ""}) == []
  end
end
```

- [ ] **Step 2:** Run: `mix test apps/dockd_cli/test/dockd_cli/output_test.exs apps/dockd_cli/test/dockd_cli/options_test.exs` — Expected: FAIL (modules undefined).

- [ ] **Step 3: Implementations**

`output.ex`:

```elixir
defmodule DockdCli.Output do
  @moduledoc "Mix-free output helpers for the standalone CLI."

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
    Enum.each(rows, &info(format_row(&1, widths)))
  end

  defp column_widths(rows) do
    arity = tuple_size(hd(rows))

    for col <- 0..(arity - 1) do
      rows |> Enum.map(&(&1 |> elem(col) |> to_string() |> String.length())) |> Enum.max()
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

`options.ex`:

```elixir
defmodule DockdCli.Options do
  @moduledoc """
  Resolves runtime Docker connection options. Precedence: explicit CLI
  flag > environment variable > absent. Mirrors the Docker CLI's own
  `--host` / `DOCKER_HOST` convention.
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

- [ ] **Step 4:** Run the two test files — Expected: PASS (7 tests).
- [ ] **Step 5:** Commit:

```bash
git add apps/dockd_cli/lib/dockd_cli/output.ex apps/dockd_cli/lib/dockd_cli/options.ex \
        apps/dockd_cli/test/dockd_cli/output_test.exs apps/dockd_cli/test/dockd_cli/options_test.exs
git commit -m "feat: add DockdCli.Output and flag/env DockdCli.Options"
```

---

### Task 3: Instance command modules — list, stop, start, restart, destroy

**Files:**
- Create `apps/dockd_cli/lib/dockd_cli/commands/instance/{list,stop,start,restart,destroy}.ex`
- Test `apps/dockd_cli/test/dockd_cli/commands/instance/lifecycle_test.exs`

**Before coding:** read the current `apps/dockd_cli/lib/mix/tasks/dockd.instance.{list,stop,start,restart,destroy}.ex` and port each success/error string and any `--all`/`--force` behavior verbatim. (Do not modify those Mix tasks.)

**Interfaces (all `run(map(), keyword()) :: :ok | {:error, term()}`):**
- `Commands.Instance.List` — consumes `Dockd.list/1`, `Dockd.Instance.short_name/1`, `Output.table/2`.
- `Commands.Instance.{Stop,Start,Restart,Destroy}` — consume `Dockd.{stop,start,restart,destroy}/2`, `Output.{info,error}`.

- [ ] **Step 1: Failing test**

```elixir
defmodule DockdCli.Commands.Instance.LifecycleTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias DockdCli.Commands.Instance.{List, Stop, Start, Restart, Destroy}

  test "list prints message when empty" do
    assert capture_io(fn -> assert List.render({:ok, []}) == :ok end) == "No dockd instances.\n"
  end

  test "list prints a table row" do
    inst = [%Dockd.Instance{name: "dockd-smoke", image: "busybox:1.37.0", running?: true, id: "abcdef0123456789"}]
    out = capture_io(fn -> List.render({:ok, inst}) end)
    assert out =~ "NAME" and out =~ "smoke" and out =~ "running" and out =~ "abcdef012345"
  end

  test "stop rejects --all with a name" do
    assert {:error, msg} = Stop.run(%{all: true, name: "smoke"}, [])
    assert msg =~ "--all"
  end

  test "start/restart/destroy require a name" do
    assert {:error, _} = Start.run(%{}, [])
    assert {:error, _} = Restart.run(%{}, [])
    assert {:error, _} = Destroy.run(%{}, [])
  end
end
```

- [ ] **Step 2:** Run: `mix test apps/dockd_cli/test/dockd_cli/commands/instance/lifecycle_test.exs` — Expected: FAIL (modules undefined).

- [ ] **Step 3: Implementations**

`list.ex`:

```elixir
defmodule DockdCli.Commands.Instance.List do
  @moduledoc "Lists dockd-managed instances as a table."
  alias Dockd.Instance
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(_args, opts), do: render(Dockd.list(opts))

  @doc false
  def render({:ok, []}), do: Output.info("No dockd instances.")
  def render({:ok, instances}), do: Output.table(Enum.map(instances, &row/1), {"NAME", "IMAGE", "STATUS", "ID"})
  def render({:error, err}), do: {:error, err}

  defp row(%Instance{} = i) do
    {Instance.short_name(i), i.image || "", if(i.running?, do: "running", else: "stopped"), short_id(i.id)}
  end

  defp short_id(nil), do: ""
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)
end
```

`stop.ex`:

```elixir
defmodule DockdCli.Commands.Instance.Stop do
  @moduledoc "Stops one dockd-managed instance, or every managed instance."
  alias Dockd.Instance
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{all: true, name: name}, _opts) when is_binary(name) and name != "",
    do: {:error, "--all cannot be combined with a positional NAME"}

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
      Enum.count(instances, fn i ->
        name = Instance.short_name(i)

        case Dockd.stop(i, opts) do
          :ok -> Output.info("Stopped #{name}") && false
          {:error, err} -> Output.error("Failed to stop #{name}: #{Exception.message(err)}") && true
        end
      end)

    if failures > 0, do: {:error, "#{failures} of #{length(instances)} instance(s) failed to stop"}, else: :ok
  end
end
```

Note: `Output.info/error` return `:ok` (truthy), so `&& false`/`&& true` yield the intended boolean. If that reads poorly, use an explicit `case` block instead.

`start.ex` / `restart.ex` / `destroy.ex` (adjust verb, success word, and any `--force`/`--all` to match the read Mix task):

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

- [ ] **Step 4:** Run the test file + `mix compile` — Expected: PASS (4 tests), clean compile.
- [ ] **Step 5:** Commit:

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/instance/list.ex \
        apps/dockd_cli/lib/dockd_cli/commands/instance/stop.ex \
        apps/dockd_cli/lib/dockd_cli/commands/instance/start.ex \
        apps/dockd_cli/lib/dockd_cli/commands/instance/restart.ex \
        apps/dockd_cli/lib/dockd_cli/commands/instance/destroy.ex \
        apps/dockd_cli/test/dockd_cli/commands/instance/lifecycle_test.exs
git commit -m "feat: add instance lifecycle command modules"
```

---

### Task 4: Instance command modules — logs, inspect

**Files:**
- Create `apps/dockd_cli/lib/dockd_cli/commands/instance/{logs,inspect}.ex`
- Test `apps/dockd_cli/test/dockd_cli/commands/instance/logs_inspect_test.exs`

**Before coding:** read `dockd.instance.logs.ex` and `dockd.instance.inspect.ex`; port the log-filter flags and the inspect output format verbatim.

**Interfaces:**
- `Commands.Instance.Logs.build_log_opts(map()) :: {:ok, keyword()} | {:error, binary()}`; `Commands.Instance.Logs.run/2` (map includes `:name`, `:tail`, `:timestamps`, `:since`, `:until`, `:stdout_only`, `:stderr_only`).
- `Commands.Instance.Inspect.run/2`.

- [ ] **Step 1: Failing test**

```elixir
defmodule DockdCli.Commands.Instance.LogsInspectTest do
  use ExUnit.Case, async: true
  alias DockdCli.Commands.Instance.{Logs, Inspect}

  test "logs requires a name" do
    assert {:error, msg} = Logs.run(%{}, [])
    assert msg =~ "NAME"
  end

  test "build_log_opts keeps passthrough filters" do
    assert {:ok, opts} = Logs.build_log_opts(%{tail: 100, timestamps: true})
    assert opts[:tail] == 100 and opts[:timestamps] == true
  end

  test "build_log_opts maps stderr_only to stream flags" do
    assert {:ok, opts} = Logs.build_log_opts(%{stderr_only: true})
    assert opts[:stdout] == false and opts[:stderr] == true
  end

  test "build_log_opts rejects both stream-only flags" do
    assert {:error, msg} = Logs.build_log_opts(%{stdout_only: true, stderr_only: true})
    assert msg =~ "mutually exclusive"
  end

  test "inspect requires a name" do
    assert {:error, msg} = Inspect.run(%{}, [])
    assert msg =~ "NAME"
  end
end
```

- [ ] **Step 2:** Run the test file — Expected: FAIL (modules undefined).

- [ ] **Step 3: Implementations**

`logs.ex`:

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
      Enum.reduce([:tail, :timestamps, :since, :until], [], fn key, acc ->
        case Map.get(args, key) do
          nil -> acc
          value -> [{key, value} | acc]
        end
      end)

    cond do
      args[:stdout_only] && args[:stderr_only] ->
        {:error, "--stdout-only and --stderr-only are mutually exclusive"}

      args[:stdout_only] -> {:ok, base ++ [stdout: true, stderr: false]}
      args[:stderr_only] -> {:ok, base ++ [stdout: false, stderr: true]}
      true -> {:ok, base}
    end
  end
end
```

`inspect.ex` (match the current task's format — read it first):

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

  defp format(raw), do: inspect(raw, pretty: true, limit: :infinity)
end
```

- [ ] **Step 4:** Run test file + `mix compile` — Expected: PASS (5 tests), clean compile.
- [ ] **Step 5:** Commit:

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/instance/logs.ex \
        apps/dockd_cli/lib/dockd_cli/commands/instance/inspect.ex \
        apps/dockd_cli/test/dockd_cli/commands/instance/logs_inspect_test.exs
git commit -m "feat: add instance logs and inspect command modules"
```

---

### Task 5: Instance `run` command module

Most complex: mutually-exclusive source flags, provisioning, interactive wait.

**Files:**
- Create `apps/dockd_cli/lib/dockd_cli/commands/instance/run.ex`
- Test `apps/dockd_cli/test/dockd_cli/commands/instance/run_test.exs`

**Before coding:** re-read `apps/dockd_cli/lib/mix/tasks/dockd.instance.run.ex` and confirm the exact signatures of `Dockd.Packages.resolve_path/1`, `Dockd.Spec.from_attrs/1`, and `Dockd.Spec.{Source,Parser,Interpolator,Normalizer}` used below.

**Interfaces:**
- `Commands.Instance.Run.validate_source_flags(map()) :: :ok | {:error, binary()}`
- `Commands.Instance.Run.connect_command(Dockd.Instance.t()) :: binary()`
- `Commands.Instance.Run.run(map(), keyword()) :: :ok | {:error, term()}`

- [ ] **Step 1: Failing test**

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
    assert Run.connect_command(%Dockd.Instance{name: "dockd-smoke", shell: "/bin/sh"}) ==
             "docker exec -it dockd-smoke /bin/sh"
  end
end
```

- [ ] **Step 2:** Run the test file — Expected: FAIL (module undefined).

- [ ] **Step 3: Implementation** (port verbatim from the Mix task; `Mix.shell().info/error` → `Output.info/error`, `exit({:shutdown, 1})` → `{:error, msg}`, read args from the map):

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
          run_apply_package(path, args[:name], short?, detached?)

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

      true -> :ok
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

  defp run_apply_package(path, name, short?, detached?) do
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

  defp apply_name_override(attrs, name) when is_binary(name) and name != "",
    do: {:ok, Map.put(attrs, :name, name)}

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
  def connect_command(%Instance{name: name, shell: shell}) when is_binary(name) and is_binary(shell),
    do: "docker exec -it #{shell_escape(name)} #{shell_escape(shell)}"

  defp shell_escape(value) when is_binary(value) do
    if value == "" or not String.match?(value, ~r/^[A-Za-z0-9_@%+=:,.\/-]+$/),
      do: "'" <> String.replace(value, "'", ~s('"'"')) <> "'",
      else: value
  end
end
```

- [ ] **Step 4:** Run test file + `mix compile` — Expected: PASS (4 tests), clean compile.
- [ ] **Step 5:** Commit:

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/instance/run.ex \
        apps/dockd_cli/test/dockd_cli/commands/instance/run_test.exs
git commit -m "feat: add instance run command module"
```

---

### Task 6: `info` + `package` command modules

**Files:**
- Create `apps/dockd_cli/lib/dockd_cli/commands/info.ex`
- Create `apps/dockd_cli/lib/dockd_cli/commands/package/{install,show,validate}.ex`
- Test `apps/dockd_cli/test/dockd_cli/commands/info_package_test.exs`

**Before coding:** read `dockd.info.ex`, `dockd.package.install.ex`, `dockd.package.show.ex`, `dockd.package.validate.ex`. Record each `@switches`, positional args, and output/error strings; port verbatim. Thread `opts` into any `Dockd.*` call that accepts per-call options (e.g. `Dockd.install_packages/2`).

**Interfaces (all `run(map(), keyword()) :: :ok | {:error, term()}`):**
- `Commands.Info` (consumes `Dockd.info/1`).
- `Commands.Package.{Install,Show,Validate}`.

- [ ] **Step 1: Failing test**

```elixir
defmodule DockdCli.Commands.InfoPackageTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias DockdCli.Commands.Info
  alias DockdCli.Commands.Package.{Install, Show, Validate}

  test "info renders sections under headers" do
    info = %{temp_files: %{count: 2, total_bytes: 10, oldest_at: nil, newest_at: nil}}
    out = capture_io(fn -> assert Info.render({:ok, info}) == :ok end)
    assert out =~ "[temp_files]" and out =~ "count: 2" and out =~ "oldest_at: -"
  end

  # Adjust these to the actual required-arg behavior read from each Mix task.
  test "package commands require their argument" do
    assert {:error, _} = Install.run(%{}, [])
    assert {:error, _} = Show.run(%{}, [])
    assert {:error, _} = Validate.run(%{}, [])
  end
end
```

- [ ] **Step 2:** Run the test file — Expected: FAIL (modules undefined).

- [ ] **Step 3: Implementations**

`info.ex`:

```elixir
defmodule DockdCli.Commands.Info do
  @moduledoc "Prints aggregate dockd state, one section per top-level key."
  alias DockdCli.Output

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(_args, opts), do: render(Dockd.info(opts))

  @doc false
  def render({:ok, info}), do: info |> Enum.sort() |> Enum.each(&render_section/1)
  def render({:error, err}), do: {:error, err}

  defp render_section({key, value}) do
    Output.info("[#{key}]")

    case value do
      %{} = map -> for {k, v} <- Enum.sort(map), do: Output.info("  #{k}: #{format_value(v)}")
      other -> Output.info("  #{format_value(other)}")
    end

    Output.info("")
  end

  defp format_value(nil), do: "-"
  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
end
```

`package/install.ex`, `package/show.ex`, `package/validate.ex`: port each Mix task's logic Mix-free. Because their exact arg shape/output is only known after reading the tasks, write each so it validates its required argument (returning `{:error, usage_string}` when missing) and delegates to the same `Dockd.*` function the task uses (`Dockd.install_packages/2` for install; the package resolve/validate helpers for show/validate), routing output through `Output`. Keep output text identical to the originals.

- [ ] **Step 4:** Run test file + `mix compile` — Expected: PASS, clean compile.
- [ ] **Step 5:** Commit:

```bash
git add apps/dockd_cli/lib/dockd_cli/commands/info.ex \
        apps/dockd_cli/lib/dockd_cli/commands/package \
        apps/dockd_cli/test/dockd_cli/commands/info_package_test.exs
git commit -m "feat: add info and package command modules"
```

---

### Task 7: `DockdCli.CLI` (Optimus spec + dispatch) and `DockdCli.Main`

**VERIFY FIRST (blocking):** open the installed Optimus docs/source (`deps/optimus`) and confirm:
1. The exact return shapes of `Optimus.parse/2` — whether `--help`/`--version` are surfaced by `parse/2` or only `parse!/2`, and the precise tuples for a subcommand match, a top-level (no-subcommand) match, and errors. Write the `DockdCli.Main.run/1` `case` to match.
2. **Where global options land in the parse result** when a subcommand matches — i.e. whether `--socket`/`--host` appear in the subcommand's `parsed.options` (the `dispatch/1` code assumes this) or in a separate top-level result. If they land elsewhere, adjust `dispatch/1`'s `Map.take` source accordingly. Also confirm a global option may appear *before* the subcommand on the command line (`dockd --socket /x instance list`).

Do not assume the shapes below are correct.

**Files:**
- Create `apps/dockd_cli/lib/dockd_cli/cli.ex`
- Create `apps/dockd_cli/lib/dockd_cli/main.ex`
- Test `apps/dockd_cli/test/dockd_cli/cli_test.exs`
- Test `apps/dockd_cli/test/dockd_cli/main_test.exs`

**Interfaces:**
- `DockdCli.CLI.spec() :: Optimus.t()` — subcommand tree plus global `--socket`/`--host` options.
- `DockdCli.CLI.dispatch({[atom()], Optimus.ParseResult.t()}) :: :ok | {:error, term()}`.
- `DockdCli.Main.run([String.t()]) :: :ok | {:error, term()}` (no halt — testable); `DockdCli.Main.main([String.t()]) :: no_return()`.

- [ ] **Step 1: Failing tests**

`cli_test.exs`:

```elixir
defmodule DockdCli.CLITest do
  use ExUnit.Case, async: true

  test "spec parses `instance list`" do
    assert {:ok, [:instance, :list], _} = Optimus.parse(DockdCli.CLI.spec(), ["instance", "list"])
  end

  test "spec parses `instance run` with flags" do
    assert {:ok, [:instance, :run], parsed} =
             Optimus.parse(DockdCli.CLI.spec(), ["instance", "run", "--image", "busybox", "--name", "w"])

    assert parsed.options.image == "busybox" and parsed.options.name == "w"
  end

  test "global --socket parses before a subcommand" do
    assert {:ok, [:instance, :list], parsed} =
             Optimus.parse(DockdCli.CLI.spec(), ["--socket", "/x.sock", "instance", "list"])

    # Adjust access path to wherever the Step-0 verification shows global
    # options land in the parse result.
    assert parsed.options.socket == "/x.sock"
  end
end
```

`main_test.exs`:

```elixir
defmodule DockdCli.MainTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  test "bare invocation prints help and succeeds" do
    out = capture_io(fn -> assert DockdCli.Main.run([]) == :ok end)
    assert out =~ "dockd"
  end

  test "unknown command returns error and writes to stderr" do
    err = capture_io(:stderr, fn -> send(self(), {:r, DockdCli.Main.run(["bogus-cmd"])}) end)
    assert_received {:r, {:error, _}}
    assert err != ""
  end
end
```

- [ ] **Step 2:** Run both test files — Expected: FAIL (modules undefined).

- [ ] **Step 3: `cli.ex`** (subcommand tree; verify Optimus option/flag/arg keyword shapes against the installed version):

```elixir
defmodule DockdCli.CLI do
  @moduledoc "Optimus command specification and dispatch for the `dockd` binary."
  alias DockdCli.Commands

  @spec spec() :: Optimus.t()
  def spec do
    Optimus.new!(
      name: "dockd",
      description: "Manage local Docker workspaces",
      version: "0.1.0",
      allow_unknown_args: false,
      parse_double_dash: true,
      global_options: [
        socket: [long: "--socket", help: "Docker socket path (overrides DOCKER_SOCKET)", required: false],
        host: [long: "--host", help: "Docker host (overrides DOCKER_HOST)", required: false]
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

  # Option/flag names MUST match the map keys the command modules read.
  defp run_options,
    do: [image: [long: "--image"], dockerfile: [long: "--dockerfile"], tag: [long: "--tag"],
         package: [long: "--package"], preset: [long: "--preset"], name: [long: "--name"]]

  defp run_flags, do: [short: [long: "--short"], detached: [long: "--detached"]]

  defp log_options,
    do: [tail: [long: "--tail", parser: :integer], since: [long: "--since", parser: :integer],
         until: [long: "--until", parser: :integer]]

  defp log_flags,
    do: [timestamps: [long: "--timestamps"], stdout_only: [long: "--stdout-only"], stderr_only: [long: "--stderr-only"]]

  defp package_install_options,
    do: [git_url: [long: "--git-url"], source: [long: "--source"], ref: [long: "--ref"]]

  @spec dispatch({[atom()], Optimus.ParseResult.t()}) :: :ok | {:error, term()}
  def dispatch({path, parsed}) do
    flags = Map.take(Map.new(parsed.options || %{}), [:socket, :host])
    opts = DockdCli.Options.resolve(flags, System.get_env())
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

Verify that `parsed.args` keys match the arg names declared here (Optimus arg names may map to `:name`/`:ref`), and that the command modules read those same keys.

- [ ] **Step 4: `main.ex`** — help bug fixed (`IO.puts(Optimus.help(spec))`, bare invocation returns `:ok`). **Adjust the `case` to the verified `Optimus.parse/2` shapes.**

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
    spec = CLI.spec()

    case Optimus.parse(spec, argv) do
      {:ok, path, parsed} ->
        report(CLI.dispatch({path, parsed}))

      {:ok, _parsed} ->
        # Top-level match with no subcommand: show help, succeed.
        IO.puts(Optimus.help(spec))
        :ok

      {:error, reasons} ->
        Enum.each(List.wrap(reasons), &Output.error/1)
        {:error, :usage}

      {:error, _path, reasons} ->
        Enum.each(List.wrap(reasons), &Output.error/1)
        {:error, :usage}
    end
  end

  defp report(:ok), do: :ok
  defp report({:error, %Dockd.Error{} = err}), do: (Output.error(Exception.message(err)); {:error, err})
  defp report({:error, msg}) when is_binary(msg), do: (Output.error(msg); {:error, msg})
  defp report({:error, other}), do: (Output.error(inspect(other)); {:error, other})

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:dockd)
    :ok
  end
end
```

If the verification in Step 0 shows `parse/2` also returns `:help`/`:version`/`{:help, path}`, add clauses returning `:ok` (and printing where appropriate). If instead those are only handled by `parse!/2`, the `--help`/`--version` flags will still work through Optimus's own handling — confirm empirically in Step 6.

- [ ] **Step 5:** Run both test files + `mix compile` — Expected: PASS, clean compile.
- [ ] **Step 6: Manual smoke via Mix:**

```bash
mix run -e 'DockdCli.Main.run(["--help"])'
mix run -e 'DockdCli.Main.run(["instance", "list"])'
```
Expected: help text prints; `instance list` prints the table or `No dockd instances.` (needs a running daemon).

- [ ] **Step 7:** Commit:

```bash
git add apps/dockd_cli/lib/dockd_cli/cli.ex apps/dockd_cli/lib/dockd_cli/main.ex \
        apps/dockd_cli/test/dockd_cli/cli_test.exs apps/dockd_cli/test/dockd_cli/main_test.exs
git commit -m "feat: add Optimus CLI spec, dispatch, and binary entrypoint"
```

---

### Task 8: Burrito release config + local build + smoke test

**VERIFY FIRST (blocking):** read the installed Burrito README/source (`deps/burrito`) and confirm the current `releases/0` shape — the `steps` entry (`&Burrito.wrap/1` vs a documented step) and the `burrito:`/`targets` key names. These have shifted across versions.

**Files:** Modify `apps/dockd_cli/mix.exs` (add `burrito` dep, `releases/0`); update `README.md`.

**Interfaces:** Produces a self-contained `dockd` executable for the host platform.

- [ ] **Step 1:** Add dep in `apps/dockd_cli/mix.exs`: `{:burrito, "~> 1.0"}`; run `mix deps.get`.

- [ ] **Step 2:** Add to `project/0`: `releases: releases(),` and:

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

Ensure the release starts `dockd_cli` (and transitively `dockd`). Adjust keys per the Step-0 verification.

- [ ] **Step 3:** Build: `MIX_ENV=prod mix release dockd` — Expected: Zig runs, `dockd` binary emitted. Install Zig if missing (`brew install zig`).

- [ ] **Step 4:** Smoke-test (adjust to emitted path):

```bash
./apps/dockd_cli/burrito_out/dockd --help
./apps/dockd_cli/burrito_out/dockd instance list
```
Expected: `--help` prints the tree; `instance list` prints the table or `No dockd instances.` against a live daemon — with no Elixir/Erlang on `PATH`.

- [ ] **Step 5:** Add a "Building the standalone CLI" section to `README.md`: Zig prerequisite, `MIX_ENV=prod mix release dockd`, binary location, and that end users need only the binary + Docker.

- [ ] **Step 6:** Commit:

```bash
git add apps/dockd_cli/mix.exs mix.lock README.md
git commit -m "build: add Burrito release for self-contained dockd binary"
```

---

## Self-Review Notes

- **Coverage:** command layer (Tasks 2–6), Optimus dispatch + entrypoint (7), flag-with-env-fallback connection opts (2, 7), Burrito local build + smoke test (8). Mix-task rewiring, ssh subcommands, and Mix-vs-binary parity are intentionally **cut** from v1 per the lean scope decisions above.
- **No runtime.exs / temp-dir handling needed.** `Dockd.Config.temp_dir/1` already resolves per-call as `opts[:temp_dir]` > `DOCKD_TEMP_DIR` env > `config :dockd, :temp_dir` > `System.tmp_dir!()/dockd` — nothing is boot-frozen, so a runtime override already works with no changes. No `--temp-dir` flag in v1 (see tech-debt note below).
- **Bug fixed:** `DockdCli.Main.run/1` prints help via `IO.puts(Optimus.help(spec))` and returns `:ok` on bare invocation (the prior `tap(Optimus.help)` emitted nothing).
- **Type consistency:** every command exposes `run(map(), keyword()) :: :ok | {:error, term()}`; `CLI.command_for/1` maps to those exact modules; `Options.resolve/1` is the sole opts source.
- **Blocking verifications flagged inline (do not assume):** `Optimus.parse/2` return variants + arg/option key names (Task 7 Step 0), Burrito `releases`/`burrito:` config keys (Task 8 Step 0), and the `Dockd.Packages`/`Dockd.Spec.*` helper signatures the `run`/`package` ports use (Tasks 5, 6 preambles). Uncertainty propagates: these modules are only "done" once checked against installed code.

## Pre-existing tech debt (out of scope — flagged, not fixed here)

`Dockd.Config.temp_dir/1` is the intended single source of truth for the temp
directory, resolving `opts[:temp_dir]` > `DOCKD_TEMP_DIR` > app config > default.
But three core call sites **bypass it** and hardcode `System.tmp_dir!()/dockd`,
so any temp-dir override (opts, env, or config) silently no-ops in those paths:

- `apps/dockd/lib/dockd/file_copy.ex:278` — `defp temp_root, do: Path.join(System.tmp_dir!(), "dockd")`
- `apps/dockd/lib/dockd/git.ex:54` — `Path.join([System.tmp_dir!(), "dockd", "dockd-fetch-..."])`
- `apps/dockd/lib/dockd/packages.ex:153` — `Path.join([System.tmp_dir!(), "dockd", "dockd-pkg-..."])`

This is why v1 does **not** add a `--temp-dir` flag: it would appear to work but
not take effect in file-copy/git-fetch/package-install. Unifying these call sites
to route through `Dockd.Config.temp_dir/1` is a separate follow-up in the `dockd`
core app, after which a `--temp-dir` flag (threaded via `opts`, exactly like
`--socket`/`--host`) becomes trivial.
```