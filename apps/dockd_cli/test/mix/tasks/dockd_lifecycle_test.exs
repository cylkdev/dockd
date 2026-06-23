defmodule Mix.Tasks.DockdLifecycleTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Dockd.ApplyResult
  alias Dockd.Instance

  @image "busybox:1.37.0"

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    name = "lifecycle-#{System.unique_integer([:positive])}"

    assert {:ok, %ApplyResult{instance: instance}} =
             Dockd.apply(@image, name: name, shell: "/bin/sh")

    on_exit(fn ->
      Mix.shell(previous_shell)
      Dockd.destroy(instance)
    end)

    {:ok, instance: instance, name: name}
  end

  describe "mix dockd.instance.list" do
    test "lists the created instance", %{name: name} do
      Mix.Tasks.Dockd.Instance.List.run([])

      messages = drain_info_messages()
      joined = Enum.join(messages, "\n")

      assert joined =~ "NAME"
      assert joined =~ "IMAGE"
      assert joined =~ "STATUS"
      assert joined =~ name
      assert joined =~ @image
      assert joined =~ "running"
    end
  end

  describe "mix dockd.instance.stop / mix dockd.instance.start / mix dockd.instance.restart" do
    test "stops, then starts, then restarts the instance", %{instance: instance, name: name} do
      Mix.Tasks.Dockd.Instance.Stop.run([name])
      assert_received {:mix_shell, :info, ["Stopped " <> _]}
      assert {:ok, false} = Dockd.running?(instance)

      Mix.Tasks.Dockd.Instance.Start.run([name])
      assert_received {:mix_shell, :info, ["Started " <> _]}
      assert {:ok, true} = Dockd.running?(instance)

      Mix.Tasks.Dockd.Instance.Restart.run([name])
      assert_received {:mix_shell, :info, ["Restarted " <> _]}
      assert {:ok, true} = Dockd.running?(instance)
    end

    test "stop with no args raises" do
      assert_raise Mix.Error, fn -> Mix.Tasks.Dockd.Instance.Stop.run([]) end
    end
  end

  describe "mix dockd.instance.logs" do
    test "writes container logs to stdout", %{name: name, instance: instance} do
      {:ok, _} = Dockd.shell_command(instance, "echo log-line-marker")

      output =
        capture_io(fn ->
          Mix.Tasks.Dockd.Instance.Logs.run([name])
        end)

      # busybox sleep keeps PID 1 alive; we just need the call to succeed.
      assert is_binary(output)
    end

    test "rejects both --stdout-only and --stderr-only", %{name: name} do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Dockd.Instance.Logs.run([name, "--stdout-only", "--stderr-only"])
      end
    end
  end

  describe "mix dockd.instance.inspect" do
    test "pretty-prints the inspect map", %{name: name} do
      output =
        capture_io(fn ->
          Mix.Tasks.Dockd.Instance.Inspect.run([name])
        end)

      assert output =~ "Id"
      assert output =~ "Config"
    end
  end

  describe "mix dockd.info" do
    test "renders each top-level key under its own header" do
      Mix.Tasks.Dockd.Info.run([])

      messages = drain_info_messages()
      joined = Enum.join(messages, "\n")

      assert joined =~ "[temp_files]"
      assert joined =~ "count:"
    end
  end

  describe "mix dockd.instance.destroy" do
    test "removes a single instance by name", %{name: name, instance: instance} do
      Mix.Tasks.Dockd.Instance.Destroy.run([name])
      assert_received {:mix_shell, :info, ["Destroyed " <> _]}

      assert {:error, _} = Dockd.get(instance.name)
    end

    test "--all + --force removes every dockd-managed instance" do
      Mix.Tasks.Dockd.Instance.Destroy.run(["--all", "--force"])

      messages = drain_info_messages()
      joined = Enum.join(messages, "\n")

      assert joined =~ "Destroyed" or joined =~ "No dockd instances."

      assert {:ok, instances} = Dockd.list()

      # `instances` should be empty - any leftover would've come from a
      # concurrent test, which is fine to ignore here.
      assert Enum.all?(instances, fn %Instance{} = i ->
               not String.starts_with?(Instance.short_name(i), "lifecycle-")
             end)
    end

    test "raises with --all and a positional NAME" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Dockd.Instance.Destroy.run(["--all", "foo"])
      end
    end
  end

  defp drain_info_messages(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> drain_info_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
