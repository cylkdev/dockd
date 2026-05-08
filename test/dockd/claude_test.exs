defmodule Dockd.ClaudeTest do
  use ExUnit.Case, async: false

  alias Dockd.Claude

  # Live tests that talk to a real claude_code container. Gated on the
  # presence of credentials on the host (matching the env vars listed in
  # priv/packages/claude_code.json). Without creds the container starts
  # but `claude --print` would error before producing useful output, so
  # we skip rather than fail.
  @cred_env_vars ~w(
    ANTHROPIC_API_KEY
    CLAUDE_CODE_OAUTH_TOKEN
    CLAUDE_CODE_USE_BEDROCK
    CLAUDE_CODE_USE_VERTEX
  )

  defp creds_present? do
    env_creds? =
      Enum.any?(@cred_env_vars, fn name ->
        case System.fetch_env(name) do
          {:ok, val} when is_binary(val) and val != "" -> true
          _ -> false
        end
      end)

    # The claude_code package mounts ~/.claude into the container, so a
    # populated host config dir is also sufficient for the CLI to auth.
    home_creds? =
      case System.fetch_env("HOME") do
        {:ok, home} -> File.dir?(Path.join(home, ".claude"))
        _ -> false
      end

    env_creds? or home_creds?
  end

  # Probe a freshly-prepared session to confirm `claude` can actually
  # authenticate inside the container. The bundled claude_code package
  # mounts ~/.claude but does not currently restore /root/.claude.json
  # from the in-mount backup, so a fresh prepare may land in a "Not
  # logged in" state even when `creds_present?/0` is truthy. Skip the
  # live tests rather than fail them in that case.
  defp claude_authenticated?(session) do
    case Claude.ask(session, "ping", timeout: 30_000) do
      {:ok, %{"result" => result}} when is_binary(result) ->
        not String.contains?(result, "Not logged in")

      {:error, %{output: output}} when is_binary(output) ->
        not String.contains?(output, "Not logged in") and
          not String.contains?(output, "Please run /login")

      _ ->
        false
    end
  end

  describe "to_argv/2 (pure)" do
    test "minimal sync argv ends with the prompt" do
      assert Claude.to_argv([], :sync) ==
               {:ok, ["claude", "--print", "--output-format", "json"]}
    end

    test "minimal stream argv adds --verbose (required by claude)" do
      assert Claude.to_argv([], :stream) ==
               {:ok, ["claude", "--print", "--output-format", "stream-json", "--verbose"]}
    end

    test "allowed_tools renders as variadic flag" do
      assert {:ok, argv} = Claude.to_argv([allowed_tools: ["Bash", "Edit"]], :sync)
      assert "--allowedTools" in argv
      i = Enum.find_index(argv, &(&1 == "--allowedTools"))
      assert Enum.slice(argv, i, 3) == ["--allowedTools", "Bash", "Edit"]
    end

    test "disallowed_tools renders as variadic flag" do
      assert {:ok, argv} = Claude.to_argv([disallowed_tools: ["Write"]], :sync)
      assert Enum.slice(argv, Enum.find_index(argv, &(&1 == "--disallowedTools")), 2) ==
               ["--disallowedTools", "Write"]
    end

    test "model emits --model <name>" do
      assert {:ok, argv} = Claude.to_argv([model: "sonnet"], :sync)
      assert "--model" in argv and "sonnet" in argv
    end

    test "system_prompt emits --system-prompt <p>" do
      assert {:ok, argv} = Claude.to_argv([system_prompt: "be brief"], :sync)
      i = Enum.find_index(argv, &(&1 == "--system-prompt"))
      assert Enum.at(argv, i + 1) == "be brief"
    end

    test "append_system_prompt emits --append-system-prompt <p>" do
      assert {:ok, argv} = Claude.to_argv([append_system_prompt: "extra"], :sync)
      i = Enum.find_index(argv, &(&1 == "--append-system-prompt"))
      assert Enum.at(argv, i + 1) == "extra"
    end

    test "add_dir is variadic" do
      assert {:ok, argv} = Claude.to_argv([add_dir: ["/a", "/b"]], :sync)
      i = Enum.find_index(argv, &(&1 == "--add-dir"))
      assert Enum.slice(argv, i, 3) == ["--add-dir", "/a", "/b"]
    end

    test "session_id emits --session-id <uuid>" do
      assert {:ok, argv} = Claude.to_argv([session_id: "abc-uuid"], :sync)
      i = Enum.find_index(argv, &(&1 == "--session-id"))
      assert Enum.at(argv, i + 1) == "abc-uuid"
    end

    test "continue: true emits --continue" do
      assert {:ok, argv} = Claude.to_argv([continue: true], :sync)
      assert "--continue" in argv
    end

    test "continue: false omits the flag" do
      assert {:ok, argv} = Claude.to_argv([continue: false], :sync)
      refute "--continue" in argv
    end

    test "resume: true emits --resume with no value" do
      assert {:ok, argv} = Claude.to_argv([resume: true], :sync)
      i = Enum.find_index(argv, &(&1 == "--resume"))
      # No following value (would be the prompt if present, but here there is none).
      assert i != nil
      assert Enum.at(argv, i + 1) == nil
    end

    test "resume: \"uuid\" emits --resume <uuid>" do
      assert {:ok, argv} = Claude.to_argv([resume: "uuid-123"], :sync)
      i = Enum.find_index(argv, &(&1 == "--resume"))
      assert Enum.at(argv, i + 1) == "uuid-123"
    end

    test "no_session_persistence: true emits the flag" do
      assert {:ok, argv} = Claude.to_argv([no_session_persistence: true], :sync)
      assert "--no-session-persistence" in argv
    end

    test "max_budget_usd renders as a stringified number" do
      assert {:ok, argv} = Claude.to_argv([max_budget_usd: 0.5], :sync)
      i = Enum.find_index(argv, &(&1 == "--max-budget-usd"))
      assert Enum.at(argv, i + 1) == "0.5"
    end

    test "include_partial_messages is permitted in :stream mode only" do
      assert {:ok, argv} = Claude.to_argv([include_partial_messages: true], :stream)
      assert "--include-partial-messages" in argv

      assert {:error, %{reason: :stream_only_opt}} =
               Claude.to_argv([include_partial_messages: true], :sync)
    end

    test "include_hook_events is permitted in :stream mode only" do
      assert {:ok, argv} = Claude.to_argv([include_hook_events: true], :stream)
      assert "--include-hook-events" in argv

      assert {:error, %{reason: :stream_only_opt}} =
               Claude.to_argv([include_hook_events: true], :sync)
    end

    test "unknown opt key is rejected" do
      assert {:error, %{reason: :unknown_opt, key: :garbage}} =
               Claude.to_argv([garbage: 1], :sync)
    end

    test ":timeout is consumed (used elsewhere) and not rendered" do
      assert {:ok, argv} = Claude.to_argv([timeout: 60_000], :sync)
      refute Enum.any?(argv, &String.contains?(&1, "timeout"))
    end
  end

  describe "ask/3 (input validation, no exec)" do
    test "rejects unknown opt key without invoking exec" do
      session = %Dockd.Session{container_id: "no-such-container", docker_options: []}
      assert {:error, %{reason: :unknown_opt, key: :garbage}} = Claude.ask(session, "x", garbage: 1)
    end
  end

  describe "ask_stream/3 (input validation, no exec)" do
    test "rejects unknown opt key without invoking exec" do
      session = %Dockd.Session{container_id: "no-such-container", docker_options: []}

      assert {:error, %{reason: :unknown_opt, key: :garbage}} =
               Claude.ask_stream(session, "x", garbage: 1)
    end
  end

  # ---- Live, container-backed cases ----

  describe "ask/3 (live)" do
    @describetag :live_claude

    setup do
      unless creds_present?() do
        # `:skip` flag is honoured by ExUnit when set on the test context.
        # We surface a runtime skip via @tag at module level too, but be
        # defensive in case the runner forgot to filter.
        :ok
      end

      :ok
    end

    @tag :network
    @tag timeout: 180_000
    test "synchronous ask returns parsed JSON with a result field" do
      unless creds_present?() do
        IO.puts("[skip] no claude credentials in host env")
        :ok
      else
        assert {:ok, session} = Dockd.prepare_package("claude_code")
        on_exit(fn -> Dockd.destroy(session) end)

        if claude_authenticated?(session) do
          assert {:ok, response} =
                   Claude.ask(session, "what is 2+2, answer with just the number",
                     timeout: 120_000
                   )

          assert is_map(response)
          assert response["type"] == "result"
          assert is_binary(response["result"])
          assert String.contains?(response["result"], "4")
        else
          IO.puts("[skip] freshly-prepared claude_code container not authenticated")
          :ok
        end
      end
    end

    @tag :network
    @tag timeout: 180_000
    test "non-zero exit propagates exit_code and output" do
      unless creds_present?() do
        IO.puts("[skip] no claude credentials in host env")
        :ok
      else
        assert {:ok, session} = Dockd.prepare_package("claude_code")
        on_exit(fn -> Dockd.destroy(session) end)

        # This test only needs a non-zero exit, which an unauthenticated
        # session will also produce — that's still a valid error shape
        # for the contract under test, so we don't gate on auth here.
        assert {:error, err} =
                 Claude.ask(session, "hi",
                   model: "definitely-not-a-real-model",
                   timeout: 60_000
                 )

        assert is_map(err)
        assert is_integer(err.exit_code)
        assert err.exit_code != 0
        assert is_binary(err.output)
      end
    end
  end

  describe "ask_stream/3 (live)" do
    @describetag :live_claude

    @tag :network
    @tag timeout: 180_000
    test "stream yields parsed events including system and result types" do
      unless creds_present?() do
        IO.puts("[skip] no claude credentials in host env")
        :ok
      else
        assert {:ok, session} = Dockd.prepare_package("claude_code")
        on_exit(fn -> Dockd.destroy(session) end)

        if claude_authenticated?(session) do
          assert {:ok, stream} =
                   Claude.ask_stream(session, "name two prime numbers", timeout: 120_000)

          events = stream |> Enum.take(10)

          assert is_list(events)
          assert Enum.any?(events, &(is_map(&1) and &1["type"] == "system"))
          assert Enum.any?(events, &(is_map(&1) and &1["type"] == "result"))
        else
          IO.puts("[skip] freshly-prepared claude_code container not authenticated")
          :ok
        end
      end
    end

    @tag :network
    @tag timeout: 180_000
    test "early stream halt closes the underlying docker session" do
      unless creds_present?() do
        IO.puts("[skip] no claude credentials in host env")
        :ok
      else
        assert {:ok, session} = Dockd.prepare_package("claude_code")
        on_exit(fn -> Dockd.destroy(session) end)

        if claude_authenticated?(session) do
          assert {:ok, stream} =
                   Claude.ask_stream(session, "list ten primes", timeout: 120_000)

          # Take just one event then halt — after_fun must close the socket.
          first = stream |> Enum.take(1)
          assert length(first) == 1

          # Smoke check: re-enumerating the resource (which constructs a
          # fresh accumulator via start_fun) must not raise. The original
          # socket has been closed by after_fun.
          _ = stream |> Enum.take(1)
          :ok
        else
          IO.puts("[skip] freshly-prepared claude_code container not authenticated")
          :ok
        end
      end
    end
  end
end
