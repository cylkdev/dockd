defmodule Dockd.Tui.CommandsTest do
  use ExUnit.Case, async: true
  alias Dockd.Tui.Commands

  test "catalog includes the core-backed commands" do
    keys = Enum.map(Commands.all(), & &1.key)
    assert :instance_run in keys
    assert :package_install in keys
    assert :info in keys
    assert :ssh_generate in keys
    assert :ssh_install in keys
  end

  test "instance_run is form-driven with an image field" do
    run = Enum.find(Commands.all(), &(&1.key == :instance_run))
    assert Enum.any?(run.fields, &(&1.key == :image and &1.required))
  end

  test "info runs immediately (no fields)" do
    info = Enum.find(Commands.all(), &(&1.key == :info))
    assert info.fields == []
  end

  test "instance action bar maps keys to actions" do
    actions = Commands.instance_actions()
    assert Enum.any?(actions, &(&1.key == ?x and &1.action == :stop))
    assert Enum.any?(actions, &(&1.key == ?s and &1.action == :shell))
  end
end
