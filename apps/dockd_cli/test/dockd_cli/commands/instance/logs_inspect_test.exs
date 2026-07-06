defmodule DockdCLI.Commands.Instance.LogsInspectTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias DockdCLI.Commands.Instance.{Logs, Inspect}

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

  test "inspect render_json emits the raw docker map as JSON" do
    map = %{"Id" => "abc", "State" => %{"Running" => true}}

    out =
      capture_io(fn ->
        assert DockdCLI.Commands.Instance.Inspect.render_json({:ok, map}) == :ok
      end)

    assert Jason.decode!(out) == map
  end

  test "inspect run_json requires a name" do
    assert {:error, msg} = DockdCLI.Commands.Instance.Inspect.run_json(%{}, [])
    assert msg =~ "Usage"
  end
end
