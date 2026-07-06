defmodule DockdCLI.Commands.TuiTest do
  use ExUnit.Case, async: true
  alias DockdCLI.Commands.Tui

  test "run launches via the injected launcher and blocks on the awaiter" do
    parent = self()

    launcher = fn opts ->
      send(parent, {:launched, opts})
      {:ok, :fake_pid}
    end

    awaiter = fn pid ->
      send(parent, {:awaited, pid})
      :ok
    end

    assert Tui.run(%{}, launcher: launcher, awaiter: awaiter) == :ok
    assert_received {:launched, launch_opts}
    assert Keyword.has_key?(launch_opts, :data) or Keyword.has_key?(launch_opts, :opts)
    assert_received {:awaited, :fake_pid}
  end

  test "run surfaces a launch failure" do
    launcher = fn _opts -> {:error, :boom} end
    assert {:error, _} = Tui.run(%{}, launcher: launcher, awaiter: fn _ -> :ok end)
  end
end
