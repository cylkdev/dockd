defmodule Dockd.Tui.DashboardTest do
  use ExUnit.Case, async: true

  alias Dockd.Tui.Dashboard
  alias Dockd.Tui.Data.Stub
  alias ExRatatui.Event

  defp state, do: elem(Dashboard.mount(data: Stub, opts: []), 1)
  defp key(code), do: %Event.Key{code: code, kind: "press"}

  test "mount starts on the instances panel in dashboard screen" do
    s = state()
    assert s.screen == :dashboard
    assert s.focus == :instances
    assert s.data == Stub
    assert s.commands != []
  end

  test "Tab toggles focus between panels" do
    {:noreply, s} = Dashboard.handle_event(key("tab"), state())
    assert s.focus == :commands
    {:noreply, s2} = Dashboard.handle_event(key("tab"), s)
    assert s2.focus == :instances
  end

  test "down moves the instance selection, clamped" do
    base = %{
      state()
      | instances: [%Dockd.Instance{id: "1", name: "a"}, %Dockd.Instance{id: "2", name: "b"}]
    }

    {:noreply, s} = Dashboard.handle_event(key("down"), base)
    assert s.selection == 1
    {:noreply, s2} = Dashboard.handle_event(key("down"), s)
    assert s2.selection == 1
  end

  test "q stops the app" do
    assert {:stop, _} = Dashboard.handle_event(key("q"), state())
  end

  test "Ctrl-C stops the app from the dashboard" do
    event = %Event.Key{code: "c", modifiers: ["ctrl"], kind: "press"}
    assert {:stop, _} = Dashboard.handle_event(event, state())
  end

  test "Ctrl-C stops the app from any screen, including a form" do
    base = state()
    command = Enum.find(base.commands, &(&1.key == :instance_run))
    form_state = %{base | screen: :form, form: Dockd.Tui.View.Form.new(command)}
    event = %Event.Key{code: "c", modifiers: ["ctrl"], kind: "press"}
    assert {:stop, _} = Dashboard.handle_event(event, form_state)
  end

  test "render shows a bottom quit hint mentioning Ctrl-C" do
    widgets = Dashboard.render(state(), %{width: 80, height: 24})
    text = widgets |> Enum.map(fn {w, _rect} -> w.text end) |> Enum.join("\n")
    assert text =~ "Ctrl-C"
    assert text =~ "quit"
  end

  test "mount schedules an initial instance refresh" do
    {:ok, _state} = Dashboard.mount(data: Dockd.Tui.Data.Stub, opts: [])
    assert_received :refresh
  end

  describe "actions" do
    alias Dockd.Tui.Data.Stub
    alias Dockd.Tui.Dashboard
    alias ExRatatui.Event

    defp dstate, do: elem(Dashboard.mount(data: Stub, opts: []), 1)
    defp dkey(code), do: %Event.Key{code: code, kind: "press"}

    defp with_instances(s),
      do: %{s | instances: [%Dockd.Instance{id: "1", name: "web", running?: true}], selection: 0}

    test "x stops the selected instance and shows working status" do
      Stub.put(:stop, :ok)
      state = with_instances(dstate())
      {:noreply, s} = Dashboard.handle_event(dkey("x"), state)
      assert match?({:working, _}, s.status)
      assert_receive {:action, _ref, :started, _}
      assert_receive {:action, _ref, :done, _}
    end

    test "d asks for confirmation before destroying" do
      state = with_instances(dstate())
      {:noreply, s} = Dashboard.handle_event(dkey("d"), state)
      assert s.confirm == {:destroy, "web"}
      refute_receive {:action, _, :started, _}, 50
    end

    test "y after d confirms and fires destroy" do
      Stub.put(:destroy, :ok)
      state = %{with_instances(dstate()) | confirm: {:destroy, "web"}}
      {:noreply, _s} = Dashboard.handle_event(dkey("y"), state)
      assert_receive {:action, _ref, :started, _}
    end

    test "Enter on a form-driven command opens the form" do
      state = %{dstate() | focus: :commands, cmd_selection: 0}
      {:noreply, s} = Dashboard.handle_event(dkey("enter"), state)
      assert s.screen == :form
      assert s.form.command.key == :instance_run
    end

    test "Enter on info runs immediately" do
      Stub.put(:info, {:ok, %{temp_files: %{count: 0}}})
      info_index = Enum.find_index(Dockd.Tui.Commands.all(), &(&1.key == :info))
      state = %{dstate() | focus: :commands, cmd_selection: info_index}
      {:noreply, s} = Dashboard.handle_event(dkey("enter"), state)
      assert s.screen == :dashboard
      assert_receive {:action, _ref, :started, _}
    end

    test "handle_info done folds a summary line into output and refreshes" do
      Stub.put(:list, {:ok, [%Dockd.Instance{id: "1", name: "web", running?: false}]})
      {:noreply, s} = Dashboard.handle_info({:action, make_ref(), :done, "stopped web"}, dstate())
      assert Enum.any?(s.output, &(&1 =~ "stopped web"))
      assert s.status == :idle
      assert [%{name: "web"}] = s.instances
    end

    test "handle_info error folds an error line prefixed with the failure mark" do
      {:noreply, s} = Dashboard.handle_info({:action, make_ref(), :error, "stop: boom"}, dstate())
      assert Enum.any?(s.output, &(&1 =~ "✗" and &1 =~ "boom"))
    end

    test "s on a running instance dispatches a shell action" do
      Dockd.Tui.Data.Stub.put(:open_shell_window, :ok)

      state = %{
        elem(Dashboard.mount(data: Dockd.Tui.Data.Stub, opts: []), 1)
        | instances: [%Dockd.Instance{id: "1", name: "web", running?: true}],
          selection: 0
      }

      receive do
        :refresh -> :ok
      after
        0 -> :ok
      end

      {:noreply, s} =
        Dashboard.handle_event(%ExRatatui.Event.Key{code: "s", kind: "press"}, state)

      assert match?({:working, _}, s.status)
      assert_receive {:action, _ref, :started, _}
    end

    test "s on a stopped instance logs not-running and does not dispatch" do
      state = %{
        elem(Dashboard.mount(data: Dockd.Tui.Data.Stub, opts: []), 1)
        | instances: [%Dockd.Instance{id: "1", name: "web", running?: false}],
          selection: 0
      }

      receive do
        :refresh -> :ok
      after
        0 -> :ok
      end

      {:noreply, s} =
        Dashboard.handle_event(%ExRatatui.Event.Key{code: "s", kind: "press"}, state)

      assert s.screen == :dashboard
      assert Enum.any?(s.output, &(&1 =~ "not running"))
      refute_receive {:action, _ref, :started, _}, 50
    end
  end

  describe "form screen + render" do
    alias Dockd.Tui.Data.Stub
    alias Dockd.Tui.Dashboard
    alias Dockd.Tui.View.Form
    alias ExRatatui.Event

    defp fstate do
      base = elem(Dashboard.mount(data: Stub, opts: []), 1)
      command = Enum.find(base.commands, &(&1.key == :instance_run))
      %{base | screen: :form, form: Form.new(command)}
    end

    test "typing in the form updates the focused field" do
      {:noreply, s} = Dashboard.handle_event(%Event.Key{code: "b", kind: "press"}, fstate())
      assert s.form.values[:image] == "b"
    end

    test "esc cancels the form back to the dashboard" do
      {:noreply, s} = Dashboard.handle_event(%Event.Key{code: "esc", kind: "press"}, fstate())
      assert s.screen == :dashboard
      assert s.form == nil
    end

    test "enter with a valid form submits and returns to the dashboard" do
      Stub.put(:run, {:ok, %Dockd.Instance{id: "1", name: "web"}})
      s0 = fstate()
      {:noreply, s1} = Dashboard.handle_event(%Event.Key{code: "b", kind: "press"}, s0)
      {:noreply, s2} = Dashboard.handle_event(%Event.Key{code: "enter", kind: "press"}, s1)
      assert s2.screen == :dashboard
      assert_receive {:action, _ref, :started, _}
    end

    test "enter with an invalid form stays and logs the error" do
      {:noreply, s} = Dashboard.handle_event(%Event.Key{code: "enter", kind: "press"}, fstate())
      assert s.screen == :form
      assert Enum.any?(s.output, &(&1 =~ "required"))
    end

    test "render returns a widget list for the dashboard screen" do
      frame = %{width: 80, height: 24}

      state = %{
        elem(Dashboard.mount(data: Stub, opts: []), 1)
        | instances: [%Dockd.Instance{id: "1", name: "web", running?: true}]
      }

      widgets = Dashboard.render(state, frame)
      assert is_list(widgets)
      assert length(widgets) >= 1
    end
  end
end
