defmodule Dockd.Tui.DataTest do
  use ExUnit.Case, async: true

  test "behaviour defines the command surface" do
    callbacks = Dockd.Tui.Data.behaviour_info(:callbacks)

    for cb <- [
          {:list, 1},
          {:logs, 2},
          {:stop, 2},
          {:start, 2},
          {:restart, 2},
          {:destroy, 2},
          {:inspect, 2},
          {:run, 2},
          {:install_package, 2},
          {:info, 1}
        ] do
      assert cb in callbacks, "missing callback #{inspect(cb)}"
    end
  end

  test "Live delegates and is a valid implementation" do
    assert Code.ensure_loaded?(Dockd.Tui.Data.Live)
    assert function_exported?(Dockd.Tui.Data.Live, :list, 1)
    assert function_exported?(Dockd.Tui.Data.Live, :run, 2)
  end
end
