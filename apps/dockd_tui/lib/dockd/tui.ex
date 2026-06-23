defmodule Dockd.Tui do
  @moduledoc """
  Minimal terminal UI: a scrolling output pane above a single-line input.

  Layout (top to bottom):

    * Output pane — fills the upper portion of the terminal. Newest text
      renders at the bottom; older text scrolls off the top.
    * Input line — one row at the bottom, prefixed by a configurable
      prompt, with a block cursor at the insertion point.

  Public API:

    * `start_link/1` — start the TUI process. Recognised options:
        * `:on_submit` — `(binary -> any)`. Called in line-edit mode when
          the user presses Enter on a non-empty input. The submitted line is
          also echoed into the output pane prefixed by the prompt.
        * `:on_input` — `(binary -> any)`. When supplied, the TUI runs in
          raw passthrough mode (see "Modes" below): the input line is hidden,
          the output pane fills the screen, and every keypress is translated
          to its raw terminal byte sequence and handed to this callback.
          `Ctrl-\\` stops the TUI.
        * `:prompt` — string drawn before the input text in line-edit mode.
          Defaults to `"> "`.
    * `append/2` — append text (possibly multi-line, possibly incomplete)
      to the output pane. Safe to call from any process.
    * `stop/1` — stop the TUI and restore the terminal.

  ## Modes

  The TUI runs in one of two modes, chosen at `start_link/1`:

    * Line-edit mode (default) — the bottom row is an editable input line
      with left/right/home/end cursor movement and backspace. Pressing Enter
      fires `:on_submit` and echoes the line. Use this for a REPL-style
      prompt. Up/Down scroll the output pane; `Ctrl-C` stops.
    * Raw passthrough mode — enabled by passing `:on_input`. The input line
      is removed, the output pane uses the full height, and individual
      keystrokes are forwarded as raw bytes (control characters, arrow-key
      escape sequences, etc.) to `:on_input`. Use this to drive an
      interactive remote process such as a container shell; `Ctrl-\\` stops.

  ## Example

      {:ok, pid} = Dockd.Tui.start_link(on_submit: fn line ->
        IO.puts("got: \#{line}")
      end)

      Dockd.Tui.append(pid, "hello from elsewhere\\n")
  """

  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph

  @default_prompt "> "
  @max_output_bytes 64_000

  @type opts :: [
          on_submit: (binary -> any),
          on_input: (binary -> any),
          prompt: binary
        ]

  @doc """
  Append `text` to the output pane. Safe to call from any process.

  `text` may be a binary or iodata, and may contain partial lines —
  trailing bytes without a newline extend the last visible line so
  streamed output renders without inserting spurious breaks.
  """
  @spec append(GenServer.server(), iodata()) :: :ok
  def append(server, text) do
    cast(server, {:append_output, IO.iodata_to_binary(text)})
  end

  @doc """
  Stop the TUI process and restore the terminal. Idempotent.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: cast(server, :stop)

  # ---------------------------------------------------------------------------
  # ExRatatui.App callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def mount(opts) do
    on_submit = Keyword.get(opts, :on_submit, fn _ -> :ok end)
    on_input = Keyword.get(opts, :on_input)
    prompt = Keyword.get(opts, :prompt, @default_prompt)

    {:ok,
     %{
       output: "",
       input: "",
       cursor: 0,
       scroll: 0,
       prompt: prompt,
       on_submit: on_submit,
       on_input: on_input
     }}
  end

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    if state.on_input do
      output = %Paragraph{
        text: visible_output(state.output, area.height, state.scroll),
        style: %Style{fg: :white}
      }

      [{output, area}]
    else
      [output_area, input_area] =
        Layout.split(area, :vertical, [{:min, 1}, {:length, 1}])

      output = %Paragraph{
        text: visible_output(state.output, output_area.height, state.scroll),
        style: %Style{fg: :white}
      }

      input = %Paragraph{
        text: render_input(state),
        style: %Style{fg: :white}
      }

      [{output, output_area}, {input, input_area}]
    end
  end

  @impl true
  def handle_event(
        %Event.Key{code: "\\", modifiers: ["ctrl"], kind: "press"},
        %{on_input: cb} = state
      )
      when not is_nil(cb) do
    {:stop, state}
  end

  def handle_event(%Event.Key{kind: "press"} = event, %{on_input: cb} = state)
      when not is_nil(cb) do
    case raw_bytes(event) do
      nil -> :ok
      bytes -> cb.(bytes)
    end

    {:noreply, state}
  end

  def handle_event(%Event.Key{code: "c", modifiers: ["ctrl"], kind: "press"}, state) do
    {:stop, state}
  end

  def handle_event(%Event.Key{code: "enter", kind: "press"}, state) do
    line = state.input

    new_output =
      state.output
      |> append_chunk(state.prompt <> line <> "\n")

    if line != "", do: state.on_submit.(line)

    {:noreply, %{state | input: "", cursor: 0, output: new_output, scroll: 0}}
  end

  def handle_event(%Event.Key{code: "backspace", kind: "press"}, state) do
    {:noreply, delete_grapheme(state)}
  end

  def handle_event(%Event.Key{code: "left", kind: "press"}, state) do
    {:noreply, %{state | cursor: max(0, state.cursor - 1)}}
  end

  def handle_event(%Event.Key{code: "right", kind: "press"}, state) do
    {:noreply, %{state | cursor: min(String.length(state.input), state.cursor + 1)}}
  end

  def handle_event(%Event.Key{code: "home", kind: "press"}, state) do
    {:noreply, %{state | cursor: 0}}
  end

  def handle_event(%Event.Key{code: "end", kind: "press"}, state) do
    {:noreply, %{state | cursor: String.length(state.input)}}
  end

  def handle_event(%Event.Key{code: "up", kind: "press"}, state) do
    {:noreply, %{state | scroll: state.scroll + 1}}
  end

  def handle_event(%Event.Key{code: "down", kind: "press"}, state) do
    {:noreply, %{state | scroll: max(0, state.scroll - 1)}}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, state)
      when is_binary(code) do
    if String.length(code) == 1 do
      {:noreply, insert_grapheme(state, code)}
    else
      {:noreply, state}
    end
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_info({:append_output, text}, state) do
    {:noreply, %{state | output: append_chunk(state.output, text), scroll: 0}}
  end

  def handle_info(:stop, state), do: {:stop, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp cast(server, msg) do
    send(server, msg)
    :ok
  end

  defp raw_bytes(%Event.Key{code: "enter"}), do: "\r"
  defp raw_bytes(%Event.Key{code: "tab"}), do: "\t"
  defp raw_bytes(%Event.Key{code: "backspace"}), do: <<0x7F>>
  defp raw_bytes(%Event.Key{code: "esc"}), do: "\e"
  defp raw_bytes(%Event.Key{code: "up"}), do: "\e[A"
  defp raw_bytes(%Event.Key{code: "down"}), do: "\e[B"
  defp raw_bytes(%Event.Key{code: "right"}), do: "\e[C"
  defp raw_bytes(%Event.Key{code: "left"}), do: "\e[D"
  defp raw_bytes(%Event.Key{code: "home"}), do: "\e[H"
  defp raw_bytes(%Event.Key{code: "end"}), do: "\e[F"
  defp raw_bytes(%Event.Key{code: "delete"}), do: "\e[3~"
  defp raw_bytes(%Event.Key{code: "page_up"}), do: "\e[5~"
  defp raw_bytes(%Event.Key{code: "page_down"}), do: "\e[6~"

  defp raw_bytes(%Event.Key{code: code, modifiers: mods}) when is_binary(code) do
    cond do
      String.length(code) != 1 -> nil
      "ctrl" in mods -> ctrl_byte(code)
      true -> code
    end
  end

  defp raw_bytes(_), do: nil

  defp ctrl_byte(<<c::utf8>>) when c in ?a..?z, do: <<c - ?a + 1>>
  defp ctrl_byte(<<c::utf8>>) when c in ?A..?Z, do: <<c - ?A + 1>>
  defp ctrl_byte("["), do: "\e"
  defp ctrl_byte("\\"), do: <<28>>
  defp ctrl_byte("]"), do: <<29>>
  defp ctrl_byte(" "), do: <<0>>
  defp ctrl_byte(_), do: nil

  defp insert_grapheme(%{input: input, cursor: pos} = state, grapheme) do
    {pre, post} = String.split_at(input, pos)
    %{state | input: pre <> grapheme <> post, cursor: pos + 1}
  end

  defp delete_grapheme(%{input: input, cursor: pos} = state) when pos > 0 do
    {pre, post} = String.split_at(input, pos)
    pre_trimmed = String.slice(pre, 0, String.length(pre) - 1)
    %{state | input: pre_trimmed <> post, cursor: pos - 1}
  end

  defp delete_grapheme(state), do: state

  defp render_input(state) do
    {pre, post} = String.split_at(state.input, state.cursor)
    state.prompt <> pre <> "█" <> post
  end

  defp append_chunk(buffer, chunk) do
    combined = buffer <> chunk

    if byte_size(combined) > @max_output_bytes do
      binary_part(combined, byte_size(combined) - @max_output_bytes, @max_output_bytes)
    else
      combined
    end
  end

  defp visible_output(text, height, scroll) do
    lines = String.split(text, "\n")
    total = length(lines)
    start = max(0, total - height - scroll)

    lines
    |> Enum.slice(start, height)
    |> Enum.join("\n")
  end
end
