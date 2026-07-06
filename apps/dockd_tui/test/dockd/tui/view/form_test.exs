defmodule Dockd.Tui.View.FormTest do
  use ExUnit.Case, async: true
  alias Dockd.Tui.View.Form
  alias Dockd.Tui.Commands

  defp run_cmd, do: Enum.find(Commands.all(), &(&1.key == :instance_run))

  test "typing fills the focused field" do
    form = run_cmd() |> Form.new() |> Form.type("b") |> Form.type("z")
    assert form.values[:image] == "bz"
  end

  test "backspace deletes from the focused field" do
    form = run_cmd() |> Form.new() |> Form.type("a") |> Form.type("b") |> Form.backspace()
    assert form.values[:image] == "a"
  end

  test "next moves focus to the following field" do
    form = run_cmd() |> Form.new() |> Form.next() |> Form.type("web")
    assert form.values[:name] == "web"
  end

  test "validate fails when a required field is blank" do
    assert {:error, msg} = run_cmd() |> Form.new() |> Form.validate()
    assert msg =~ "Image"
  end

  test "validate passes once required fields are set" do
    assert :ok = run_cmd() |> Form.new() |> Form.type("busybox") |> Form.validate()
  end

  test "render shows the command label and field labels" do
    out = run_cmd() |> Form.new() |> Form.render()
    assert out =~ "instance run"
    assert out =~ "Image"
  end
end
