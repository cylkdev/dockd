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
