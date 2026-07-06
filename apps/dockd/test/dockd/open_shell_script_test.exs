defmodule Dockd.OpenShellScriptTest do
  # Hermetic test for apps/dockd/priv/open-shell. Uses a stub $TERMINAL that
  # records its argv to a file, so no real window opens and it runs on any OS.
  use ExUnit.Case, async: true

  @launcher Path.join(:code.priv_dir(:dockd), "open-shell")

  setup do
    tmp = Path.join(System.tmp_dir!(), "open-shell-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    record = Path.join(tmp, "record.txt")
    stub = Path.join(tmp, "fake-term")
    File.write!(stub, ~s(#!/bin/sh\nprintf '%s\\n' "$@" > "#{record}"\n))
    File.chmod!(stub, 0o755)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, stub: stub, record: record}
  end

  test "invokes $TERMINAL with the passed command", %{stub: stub, record: record} do
    {_out, code} =
      System.cmd(@launcher, ["docker exec -it dockd-web /bin/sh"],
        env: [{"TERMINAL", stub}],
        stderr_to_stdout: true
      )

    assert code == 0
    args = File.read!(record)
    assert args =~ "-e"
    assert args =~ "docker exec -it dockd-web /bin/sh"
  end

  test "errors when no command is given", %{stub: stub} do
    {out, code} =
      System.cmd(@launcher, [], env: [{"TERMINAL", stub}], stderr_to_stdout: true)

    assert code != 0
    assert out =~ "open-shell"
  end
end
