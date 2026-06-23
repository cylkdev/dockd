defmodule Dockd.AppBoundaryTest do
  use ExUnit.Case, async: true

  test "core app does not depend on RPC app" do
    applications = Application.spec(:dockd, :applications) || []

    refute :dockd_rpc in applications
  end
end
