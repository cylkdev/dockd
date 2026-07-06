defmodule Dockd.Tui.Dashboard do
  @moduledoc """
  The dockd dashboard: an `ExRatatui.App` presenting a live instance list and a
  command list, with a feedback pane below. Its only Docker seam is the
  `Dockd.Tui.Data` module in state, so `handle_event/2` and `handle_info/2` are
  unit-tested against `Dockd.Tui.Data.Stub`. Commands run in `Dockd.Tui.Action`
  Tasks that message results back here.
  """
  use ExRatatui.App

  alias ExRatatui.Event

  @impl true
  def mount(opts) do
    data = Keyword.get(opts, :data, Dockd.Tui.Data.Live)
    conn_opts = Keyword.get(opts, :opts, [])

    state = %{
      screen: :dashboard,
      focus: :instances,
      data: data,
      opts: conn_opts,
      instances: [],
      selection: 0,
      commands: Dockd.Tui.Commands.all(),
      cmd_selection: 0,
      output: [],
      status: :idle,
      form: nil,
      confirm: nil
    }

    send(self(), :refresh)
    {:ok, state}
  end

  # --- navigation (dashboard screen) ---

  @impl true
  def handle_event(%Event.Key{code: "c", modifiers: ["ctrl"], kind: "press"}, state) do
    {:stop, state}
  end

  def handle_event(%Event.Key{code: "q", kind: "press"}, %{screen: :dashboard} = state) do
    {:stop, state}
  end

  def handle_event(%Event.Key{code: "tab", kind: "press"}, %{screen: :dashboard} = state) do
    {:noreply, %{state | focus: toggle(state.focus)}}
  end

  def handle_event(
        %Event.Key{code: "down", kind: "press"},
        %{screen: :dashboard, focus: :instances} = state
      ) do
    {:noreply, %{state | selection: clamp(state.selection + 1, state.instances)}}
  end

  def handle_event(
        %Event.Key{code: "up", kind: "press"},
        %{screen: :dashboard, focus: :instances} = state
      ) do
    {:noreply, %{state | selection: max(state.selection - 1, 0)}}
  end

  def handle_event(
        %Event.Key{code: "down", kind: "press"},
        %{screen: :dashboard, focus: :commands} = state
      ) do
    {:noreply, %{state | cmd_selection: clamp(state.cmd_selection + 1, state.commands)}}
  end

  def handle_event(
        %Event.Key{code: "up", kind: "press"},
        %{screen: :dashboard, focus: :commands} = state
      ) do
    {:noreply, %{state | cmd_selection: max(state.cmd_selection - 1, 0)}}
  end

  # --- instance action keys ---

  def handle_event(
        %Event.Key{code: "y", kind: "press"},
        %{screen: :dashboard, confirm: {verb, name}} = state
      ) do
    {:noreply, dispatch(%{state | confirm: nil}, {verb, name})}
  end

  def handle_event(%Event.Key{kind: "press"}, %{screen: :dashboard, confirm: {_, _}} = state) do
    {:noreply, %{state | confirm: nil, output: log(state, "cancelled")}}
  end

  def handle_event(
        %Event.Key{code: code, kind: "press"},
        %{screen: :dashboard, focus: :instances} = state
      )
      when is_binary(code) and byte_size(code) == 1 do
    case {instance_action(code), selected_instance(state)} do
      {nil, _} ->
        {:noreply, state}

      {_action, nil} ->
        {:noreply, state}

      {:shell, instance} ->
        if instance.running? do
          {:noreply, dispatch(state, {:shell, instance.name})}
        else
          {:noreply, %{state | output: log(state, "✗ #{instance.name} is not running")}}
        end

      {:destroy, instance} ->
        {:noreply, %{state | confirm: {:destroy, instance.name}}}

      {action, instance} ->
        {:noreply, dispatch(state, {action, instance.name})}
    end
  end

  # --- command panel Enter ---

  def handle_event(
        %Event.Key{code: "enter", kind: "press"},
        %{screen: :dashboard, focus: :commands} = state
      ) do
    command = Enum.at(state.commands, state.cmd_selection)

    if command.fields == [] do
      {:noreply, dispatch(state, {command.key, %{}})}
    else
      {:noreply, %{state | screen: :form, form: Dockd.Tui.View.Form.new(command)}}
    end
  end

  # --- form screen ---

  def handle_event(%Event.Key{code: "esc", kind: "press"}, %{screen: :form} = state) do
    {:noreply, %{state | screen: :dashboard, form: nil}}
  end

  def handle_event(%Event.Key{code: "enter", kind: "press"}, %{screen: :form} = state) do
    case Dockd.Tui.View.Form.validate(state.form) do
      :ok ->
        spec = {state.form.command.key, Dockd.Tui.View.Form.values(state.form)}
        Dockd.Tui.Action.run(self(), state.data, spec, state.opts)

        {:noreply,
         %{
           state
           | screen: :dashboard,
             form: nil,
             status: {:working, Dockd.Tui.Action.label(spec)}
         }}

      {:error, message} ->
        {:noreply, %{state | output: log(state, "✗ #{message}")}}
    end
  end

  def handle_event(%Event.Key{code: "backspace", kind: "press"}, %{screen: :form} = state) do
    {:noreply, %{state | form: Dockd.Tui.View.Form.backspace(state.form)}}
  end

  def handle_event(%Event.Key{code: "down", kind: "press"}, %{screen: :form} = state) do
    {:noreply, %{state | form: Dockd.Tui.View.Form.next(state.form)}}
  end

  def handle_event(%Event.Key{code: "up", kind: "press"}, %{screen: :form} = state) do
    {:noreply, %{state | form: Dockd.Tui.View.Form.prev(state.form)}}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, %{screen: :form} = state)
      when is_binary(code) and byte_size(code) == 1 do
    {:noreply, %{state | form: Dockd.Tui.View.Form.type(state.form, code)}}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_info({:action, _ref, :started, label}, state) do
    {:noreply, %{state | status: {:working, label}, output: log(state, "⟳ #{label}…")}}
  end

  def handle_info({:action, _ref, :done, summary}, state) do
    {:noreply, refresh(%{state | status: :idle, output: log(state, "✓ #{summary}")})}
  end

  def handle_info({:action, _ref, :error, message}, state) do
    {:noreply, %{state | status: :idle, output: log(state, "✗ #{message}")}}
  end

  def handle_info(:refresh, state), do: {:noreply, refresh(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def render(%{screen: :form} = state, frame) do
    area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [{paragraph(Dockd.Tui.View.Form.render(state.form)), area}]
  end

  def render(state, frame) do
    area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [list_area, bar_area, output_area, footer_area] =
      ExRatatui.Layout.split(area, :vertical, [
        {:min, 3},
        {:length, 1},
        {:length, 8},
        {:length, 1}
      ])

    list_text =
      case state.focus do
        :instances -> Dockd.Tui.View.Instances.render(state.instances, state.selection)
        :commands -> Dockd.Tui.View.Commands.render(state.commands, state.cmd_selection)
      end

    [
      {paragraph(list_text), list_area},
      {paragraph(action_bar(state)), bar_area},
      {paragraph(Dockd.Tui.View.Output.render(state.output, output_area.height)), output_area},
      {paragraph(footer()), footer_area}
    ]
  end

  defp action_bar(%{confirm: {:destroy, name}}), do: "Destroy #{name}? [y] yes  [any] no"

  defp action_bar(%{focus: :instances}) do
    Dockd.Tui.Commands.instance_actions() |> Enum.map(& &1.label) |> Enum.join(" ")
  end

  defp action_bar(%{focus: :commands}), do: "[Enter] run/open  [Tab] instances"

  # Persistent bottom hint so users always know how to leave the dashboard.
  defp footer, do: "q or Ctrl-C: quit   ·   Tab: switch panel"

  defp paragraph(text) do
    %ExRatatui.Widgets.Paragraph{text: text, style: %ExRatatui.Style{fg: :white}}
  end

  # --- internal ---

  defp toggle(:instances), do: :commands
  defp toggle(:commands), do: :instances

  defp clamp(index, list) when is_list(list) do
    max_index = max(length(list) - 1, 0)
    min(index, max_index)
  end

  defp dispatch(state, {verb, name} = spec) do
    Dockd.Tui.Action.run(self(), state.data, spec, state.opts)

    %{
      state
      | status: {:working, Dockd.Tui.Action.label(spec)},
        output: log(state, "⟳ #{verb} #{inspect_target(name)}…")
    }
  end

  defp inspect_target(name) when is_binary(name), do: name
  defp inspect_target(_), do: ""

  defp instance_action(code) do
    char = :binary.first(code)

    Dockd.Tui.Commands.instance_actions()
    |> Enum.find_value(fn %{key: k, action: a} -> if k == char, do: a end)
  end

  defp selected_instance(state), do: Enum.at(state.instances, state.selection)

  defp refresh(state) do
    case state.data.list(state.opts) do
      {:ok, instances} ->
        %{state | instances: instances, selection: clamp(state.selection, instances)}

      {:error, reason} ->
        %{state | output: log(state, "✗ list: #{inspect(reason)}")}
    end
  end

  defp log(state, line), do: Dockd.Tui.View.Output.append(state.output, line)
end
