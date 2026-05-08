defmodule Dockd.Claude do
  @moduledoc """
  Programmatic Q&A against a `claude --print` process inside a prepared
  `Dockd.Workspace`.

  This module wraps the Claude Code CLI's non-interactive print mode so
  callers can ask questions and receive structured replies without
  attaching a PTY. There are two entry points:

    - `ask/3` runs `claude --print --output-format json …` via
      `Docker.exec_run_with_status/3`, waits for the process to exit,
      and decodes the single JSON result object.
    - `ask_stream/3` runs `claude --print --output-format stream-json
      --verbose …` via `Docker.exec_session/3` and returns a lazy
      `Stream` that yields newline-delimited JSON events as they arrive.

  Neither function attaches stdin to the inner process; the prompt is
  passed positionally on the command line. This avoids the PTY and
  attach issues that arise when piping into the interactive REPL.

  ## Distinct from the human REPL

  `Dockd` itself is concerned with provisioning a workspace and handing
  back a `session.shell_command` string a human can paste into a
  terminal. `Dockd.Claude` is the programmatic counterpart: it does not
  produce a shell command, it makes individual Q&A calls.

  ## Example

      {:ok, session} = Dockd.prepare_package("claude_code")
      {:ok, response} = Dockd.Claude.ask(session, "what is 2+2")
      response["result"]
      #=> "4"

  Credentials must be present in the container (mounted `~/.claude` or
  one of the credential env vars passed through via the package's
  `:env`).
  """

  alias Dockd.Workspace
  alias Docker.Engine.Streaming.Session

  @type response :: map()

  @type ask_opts :: [
          allowed_tools: [binary()],
          disallowed_tools: [binary()],
          model: binary(),
          system_prompt: binary(),
          append_system_prompt: binary(),
          add_dir: [binary()],
          session_id: binary(),
          continue: boolean(),
          resume: binary() | true,
          no_session_persistence: boolean(),
          max_budget_usd: number(),
          timeout: pos_integer()
        ]

  @type stream_opts :: [
          allowed_tools: [binary()],
          disallowed_tools: [binary()],
          model: binary(),
          system_prompt: binary(),
          append_system_prompt: binary(),
          add_dir: [binary()],
          session_id: binary(),
          continue: boolean(),
          resume: binary() | true,
          no_session_persistence: boolean(),
          max_budget_usd: number(),
          timeout: pos_integer(),
          include_partial_messages: boolean(),
          include_hook_events: boolean()
        ]

  @type ask_error :: %{
          optional(:reason) => atom(),
          optional(:key) => atom(),
          optional(:exit_code) => integer(),
          optional(:output) => binary(),
          optional(:message) => binary()
        }

  # Keys recognised in either mode.
  @shared_opt_keys [
    :allowed_tools,
    :disallowed_tools,
    :model,
    :system_prompt,
    :append_system_prompt,
    :add_dir,
    :session_id,
    :continue,
    :resume,
    :no_session_persistence,
    :max_budget_usd,
    :timeout
  ]

  # Keys recognised only in :stream mode.
  @stream_only_opt_keys [:include_partial_messages, :include_hook_events]

  # Default :until-read budget per stream-json line. Generous because the
  # `system` event waits on the model spinning up.
  @default_stream_chunk_timeout 120_000

  @doc """
  Asks Claude a single question inside `session` and returns the parsed
  JSON result.

  Builds `claude --print --output-format json …` from `opts`, runs it
  via `Docker.exec_run_with_status/3`, and decodes the single JSON
  object the CLI emits on stdout.

  ## Returns

    - `{:ok, decoded}` - exit code was 0 and stdout parsed as JSON.
    - `{:error, %{reason: :unknown_opt, key: atom}}` - `opts` contained
      an unrecognised key. No exec is performed.
    - `{:error, %{reason: :invalid_json, output: binary}}` - exit code
      was 0 but stdout was not valid JSON.
    - `{:error, %{exit_code: int, output: binary}}` - the CLI exited
      non-zero. `output` is the merged stdout+stderr returned by the
      Docker exec primitive.
    - `{:error, term}` - anything else propagated from the Docker layer.

  ## Options

  See `t:ask_opts/0`. `:timeout` (in milliseconds) is forwarded to the
  Docker exec primitive as `:receive_timeout`; all other recognised
  keys map to CLI flags via `to_argv/2`.
  """
  @spec ask(Workspace.t(), binary(), ask_opts()) :: {:ok, response()} | {:error, term()}
  def ask(%Workspace{} = session, prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    with {:ok, argv} <- to_argv(opts, :sync) do
      argv = argv ++ [prompt]
      exec_opts = build_exec_opts(session, opts)

      case Docker.exec_run_with_status(session.container_id, argv, exec_opts) do
        {:ok, %{exit_code: 0, output: output}} ->
          decode_sync_output(output)

        {:ok, %{exit_code: code, output: output}} ->
          {:error, %{exit_code: code, output: output}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Asks Claude a question and returns a lazy stream of parsed JSON
  events.

  Builds `claude --print --output-format stream-json --verbose …` from
  `opts`, opens an exec session via `Docker.exec_session/3`, and wraps
  the socket in `Stream.resource/3`. Each line of stdout is decoded
  with `Jason.decode!/1` and emitted as a map.

  Halting the stream early (via `Enum.take/2` or similar) closes the
  underlying socket via the resource's `after_fun`.

  ## Returns

    - `{:ok, stream}` - the resource is ready to enumerate. Items are
      maps with at least a `"type"` field (`"system"`, `"assistant"`,
      `"result"`, …).
    - `{:error, %{reason: :unknown_opt, key: atom}}` - `opts` contained
      an unrecognised key. No exec is performed.
    - `{:error, %{reason: :stream_only_opt, key: atom}}` - propagated
      from `to_argv/2` if a stream-only key reaches the sync path
      (cannot happen here in practice).
    - `{:error, term}` - anything else propagated from the Docker layer.

  Each line is decoded with `Jason.decode!/1`; a malformed line will
  raise `Jason.DecodeError` from inside the stream - the CLI is
  contractually expected to emit valid newline-delimited JSON.
  """
  @spec ask_stream(Workspace.t(), binary(), stream_opts()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def ask_stream(%Workspace{} = session, prompt, opts \\ [])
      when is_binary(prompt) and is_list(opts) do
    with {:ok, argv} <- to_argv(opts, :stream) do
      argv = argv ++ [prompt]

      exec_opts =
        session.docker_options
        |> Keyword.put(:attach_stdin, false)
        |> Keyword.put(:tty, false)

      timeout = Keyword.get(opts, :timeout, @default_stream_chunk_timeout)

      case Docker.exec_session(session.container_id, argv, exec_opts) do
        {:ok, exec_session} ->
          {:ok, build_event_stream(exec_session, timeout)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Builds the argv list for a `claude --print …` invocation from `opts`.

  Pure function exposed for testing. `mode` selects between the
  synchronous (`:sync`) and streaming (`:stream`) output formats. The
  prompt is *not* included - callers append it as the final positional
  argument.

  Returns `{:ok, argv}` on success, or `{:error, %{reason: …}}` if an
  option key is unknown for the chosen mode.
  """
  @spec to_argv(keyword(), :sync | :stream) ::
          {:ok, [binary()]} | {:error, %{reason: atom(), key: atom()}}
  def to_argv(opts, :sync) when is_list(opts) do
    with :ok <- check_opt_keys(opts, :sync) do
      base = ["claude", "--print", "--output-format", "json"]
      {:ok, base ++ build_flag_args(opts, :sync)}
    end
  end

  def to_argv(opts, :stream) when is_list(opts) do
    with :ok <- check_opt_keys(opts, :stream) do
      # stream-json on this CLI requires --verbose alongside --print.
      base = ["claude", "--print", "--output-format", "stream-json", "--verbose"]
      {:ok, base ++ build_flag_args(opts, :stream)}
    end
  end

  # ---------------------------------------------------------------------------

  defp check_opt_keys(opts, mode) do
    allowed =
      case mode do
        :sync -> @shared_opt_keys
        :stream -> @shared_opt_keys ++ @stream_only_opt_keys
      end

    Enum.reduce_while(opts, :ok, fn {k, _v}, :ok ->
      cond do
        k in allowed ->
          {:cont, :ok}

        mode == :sync and k in @stream_only_opt_keys ->
          {:halt, {:error, %{reason: :stream_only_opt, key: k}}}

        true ->
          {:halt, {:error, %{reason: :unknown_opt, key: k}}}
      end
    end)
  end

  defp build_flag_args(opts, mode), do: Enum.flat_map(opts, &opt_to_argv(&1, mode))

  # :timeout is consumed by the exec layer, not the CLI.
  defp opt_to_argv({:timeout, _}, _mode), do: []

  defp opt_to_argv({:allowed_tools, list}, _mode) when is_list(list) and list !== [],
    do: ["--allowedTools" | Enum.map(list, &to_string/1)]

  defp opt_to_argv({:allowed_tools, _}, _mode), do: []

  defp opt_to_argv({:disallowed_tools, list}, _mode) when is_list(list) and list !== [],
    do: ["--disallowedTools" | Enum.map(list, &to_string/1)]

  defp opt_to_argv({:disallowed_tools, _}, _mode), do: []

  defp opt_to_argv({:model, name}, _mode) when is_binary(name),
    do: ["--model", name]

  defp opt_to_argv({:system_prompt, p}, _mode) when is_binary(p),
    do: ["--system-prompt", p]

  defp opt_to_argv({:append_system_prompt, p}, _mode) when is_binary(p),
    do: ["--append-system-prompt", p]

  defp opt_to_argv({:add_dir, list}, _mode) when is_list(list) and list !== [],
    do: ["--add-dir" | Enum.map(list, &to_string/1)]

  defp opt_to_argv({:add_dir, _}, _mode), do: []

  defp opt_to_argv({:session_id, uuid}, _mode) when is_binary(uuid),
    do: ["--session-id", uuid]

  defp opt_to_argv({:continue, true}, _mode), do: ["--continue"]
  defp opt_to_argv({:continue, _}, _mode), do: []

  defp opt_to_argv({:resume, true}, _mode), do: ["--resume"]
  defp opt_to_argv({:resume, uuid}, _mode) when is_binary(uuid), do: ["--resume", uuid]
  defp opt_to_argv({:resume, _}, _mode), do: []

  defp opt_to_argv({:no_session_persistence, true}, _mode), do: ["--no-session-persistence"]
  defp opt_to_argv({:no_session_persistence, _}, _mode), do: []

  defp opt_to_argv({:max_budget_usd, n}, _mode) when is_number(n),
    do: ["--max-budget-usd", number_to_string(n)]

  defp opt_to_argv({:include_partial_messages, true}, :stream), do: ["--include-partial-messages"]
  defp opt_to_argv({:include_partial_messages, _}, :stream), do: []

  defp opt_to_argv({:include_hook_events, true}, :stream), do: ["--include-hook-events"]
  defp opt_to_argv({:include_hook_events, _}, :stream), do: []

  # Anything that survived check_opt_keys/2 but didn't match a clause:
  # be tolerant - drop it.
  defp opt_to_argv(_, _), do: []

  defp number_to_string(n) when is_integer(n), do: Integer.to_string(n)
  defp number_to_string(n) when is_float(n), do: :erlang.float_to_binary(n, [:short])

  defp build_exec_opts(%Workspace{docker_options: docker_options}, opts) do
    case Keyword.fetch(opts, :timeout) do
      {:ok, t} when is_integer(t) and t > 0 ->
        Keyword.put(docker_options, :receive_timeout, t)

      _ ->
        docker_options
    end
  end

  defp decode_sync_output(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, %{reason: :invalid_json, output: output}}
    end
  end

  # Stream construction.
  #
  # The accumulator carries the live `Docker.Engine.Streaming.Session.t()` (which is
  # stateful - recv/3 returns an updated session each call) plus a
  # leftover-buffer string for any partial line read at the previous
  # boundary.
  defp build_event_stream(exec_session, timeout) do
    Stream.resource(
      fn -> {exec_session, ""} end,
      fn state -> next_events(state, timeout) end,
      fn {s, _leftover} -> Session.close(s) end
    )
  end

  # Returns {events, new_state} | {:halt, state}.
  defp next_events({session, leftover}, timeout) do
    case Session.recv(session, {:until, "\n"}, timeout: timeout) do
      {:ok, chunk, session2} ->
        # `chunk` includes everything up to and including the newline.
        combined = leftover <> chunk
        {lines, new_leftover} = split_complete_lines(combined)
        events = decode_lines(lines)
        {events, {session2, new_leftover}}

      {:error, :closed_before_delimiter, session2} ->
        flush_leftover(leftover, session2)

      {:error, :closed, session2} ->
        flush_leftover(leftover, session2)

      {:error, _reason, session2} ->
        # Surface as halt; after_fun will close.
        {:halt, {session2, leftover}}
    end
  end

  # Splits `buffer` on newlines into a list of complete lines plus a
  # trailing partial. `String.split/2` returns a list whose last element
  # is the bytes after the final `\n` (or the entire buffer if no
  # newline appeared at all). Everything before the last element is a
  # fully-terminated line.
  defp split_complete_lines(buffer) do
    parts = String.split(buffer, "\n")
    {trailing, complete_with_blanks} = List.pop_at(parts, -1)
    complete = Enum.reject(complete_with_blanks, &(&1 === ""))
    {complete, trailing || ""}
  end

  defp decode_lines(lines) do
    Enum.map(lines, &Jason.decode!/1)
  end

  defp flush_leftover("", session), do: {:halt, {session, ""}}

  defp flush_leftover(leftover, session) do
    case Jason.decode(leftover) do
      # Emit the final event, then on the next call we'll see {leftover: ""}
      # plus a closed session - recv returns {:error, :closed, _}, which
      # will halt cleanly.
      {:ok, event} -> {[event], {session, ""}}
      {:error, _} -> {:halt, {session, ""}}
    end
  end
end
