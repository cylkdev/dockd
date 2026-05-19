defmodule Mix.Tasks.Dockd.Instance.RunTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  @image "busybox:1.37.0"
  @fixtures_dir Path.expand("../../fixtures", __DIR__)
  @dockerfile Path.join(@fixtures_dir, "Dockerfile")

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  describe "run/1 with --image" do
    test "starts a container with the specified image" do
      capture_io([input: "\n"], fn ->
        Mix.Tasks.Dockd.Instance.Run.run(["--image", @image])
      end)

      assert_received {:mix_shell, :info, [pulling_msg]}
      assert pulling_msg =~ "Pulling #{@image}"

      assert_received {:mix_shell, :info, [ready_msg]}
      assert ready_msg =~ "Container is ready!"
      assert ready_msg =~ "docker exec -it"

      assert_received {:mix_shell, :info, ["Stopping container..."]}
      assert_received {:mix_shell, :info, ["Done - container removed."]}
    end
  end

  describe "run/1 with --detached" do
    test "starts a container, prints connect + destroy hints, exits without destroying" do
      capture_io(fn ->
        Mix.Tasks.Dockd.Instance.Run.run(["--image", @image, "--detached"])
      end)

      assert_received {:mix_shell, :info, [pulling_msg]}
      assert pulling_msg =~ "Pulling #{@image}"

      assert_received {:mix_shell, :info, [ready_msg]}
      assert ready_msg =~ "Container is ready (detached"
      assert ready_msg =~ "Connect:"
      assert ready_msg =~ "docker exec -it"
      assert ready_msg =~ "Destroy:"

      refute_received {:mix_shell, :info, ["Stopping container..."]}
      refute_received {:mix_shell, :info, ["Done - container removed."]}

      [_, container_name] = Regex.run(~r/docker exec -it (\S+)/, ready_msg)
      assert Docker.container_running?(container_name)
      :ok = Dockd.destroy(container_name)
    end
  end

  describe "run/1 with --short" do
    test "prints only the docker command and emits no banner messages" do
      output =
        capture_io([input: "\n"], fn ->
          Mix.Tasks.Dockd.Instance.Run.run(["--image", @image, "--short"])
        end)

      assert output =~ "docker exec -it"
      refute output =~ "Container is ready!"
      refute output =~ "Pulling"

      refute_received {:mix_shell, :info, _}
    end
  end

  describe "run/1 with defaults" do
    test "uses debian:trixie when no flags are provided" do
      capture_io([input: "\n"], fn ->
        Mix.Tasks.Dockd.Instance.Run.run([])
      end)

      assert_received {:mix_shell, :info, [pulling_msg]}
      assert pulling_msg =~ "Pulling debian:trixie"
    end
  end

  describe "run/1 with --dockerfile" do
    test "builds from a Dockerfile and starts a container" do
      capture_io([input: "\n"], fn ->
        Mix.Tasks.Dockd.Instance.Run.run(["--dockerfile", @dockerfile])
      end)

      assert_received {:mix_shell, :info, [building_msg]}
      assert building_msg =~ "Building from #{@dockerfile}"

      assert_received {:mix_shell, :info, [ready_msg]}
      assert ready_msg =~ "Container is ready!"
      assert ready_msg =~ "docker exec -it"

      assert_received {:mix_shell, :info, ["Stopping container..."]}
      assert_received {:mix_shell, :info, ["Done - container removed."]}
    end

    test "builds from a directory containing a Dockerfile" do
      capture_io([input: "\n"], fn ->
        Mix.Tasks.Dockd.Instance.Run.run(["--dockerfile", @fixtures_dir])
      end)

      assert_received {:mix_shell, :info, [building_msg]}
      assert building_msg =~ "Building from #{@fixtures_dir}"

      assert_received {:mix_shell, :info, [ready_msg]}
      assert ready_msg =~ "Container is ready!"
    end

    test "uses --tag as the image tag" do
      tag = "dockd-mix-test:custom-#{System.unique_integer([:positive])}"

      capture_io([input: "\n"], fn ->
        Mix.Tasks.Dockd.Instance.Run.run(["--dockerfile", @dockerfile, "--tag", tag])
      end)

      assert_received {:mix_shell, :info, [_building_msg]}

      assert_received {:mix_shell, :info, [ready_msg]}
      assert ready_msg =~ "Container is ready!"
    end
  end

  describe "run/1 with invalid input" do
    test "prints error and exits when dockerfile does not exist" do
      assert catch_exit(
               capture_io([input: "\n"], fn ->
                 Mix.Tasks.Dockd.Instance.Run.run(["--dockerfile", "/nonexistent/Dockerfile"])
               end)
             ) === {:shutdown, 1}

      assert_received {:mix_shell, :error, [error_msg]}
      assert error_msg =~ "Failed during"
      assert error_msg =~ "does not exist"
    end
  end
end
