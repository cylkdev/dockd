defmodule DockdCli.OptionsTest do
  use ExUnit.Case, async: true
  alias DockdCli.Options

  test "empty when nothing set" do
    assert Options.resolve(%{}, %{}) == []
  end

  test "reads socket and host from env" do
    opts =
      Options.resolve(%{}, %{"DOCKER_SOCKET" => "/run/d.sock", "DOCKER_HOST" => "tcp://x:2375"})

    assert opts[:socket] == "/run/d.sock"
    assert opts[:host] == "tcp://x:2375"
  end

  test "flag overrides env" do
    opts = Options.resolve(%{socket: "/from/flag.sock"}, %{"DOCKER_SOCKET" => "/from/env.sock"})
    assert opts[:socket] == "/from/flag.sock"
  end

  test "ignores blank values" do
    assert Options.resolve(%{socket: nil, host: ""}, %{"DOCKER_SOCKET" => ""}) == []
  end
end
