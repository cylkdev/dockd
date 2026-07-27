defmodule DockdTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Dockd.ApplyResult
  alias Dockd.Instance

  @image "busybox:1.37.0"

  describe "shell_command/2" do
    test "runs a string command and returns combined output with exit code" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, %{output: "hello\n", exit_code: 0}} =
               Dockd.shell_command(instance, "echo hello")
    end

    test "runs an argv list verbatim and surfaces non-zero exit codes" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, %{exit_code: 0}} = Dockd.shell_command(instance, ["true"])

      assert {:ok, %{exit_code: code}} =
               Dockd.shell_command(instance, ["sh", "-c", "exit 3"])

      assert code === 3
    end
  end

  describe "open_shell / shell_send / close_shell" do
    test "persistent shell preserves state between commands" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, shell} = Dockd.open_shell(instance)
      assert {:ok, {_, shell}} = Dockd.shell_send(shell, "cd /tmp")
      assert {:ok, {out, shell}} = Dockd.shell_send(shell, "pwd")
      assert String.contains?(out, "/tmp")
      assert :ok = Dockd.close_shell(shell)
    end

    test "defaults the session program to the instance's configured shell" do
      # "cat" echoes stdin verbatim, so a line sent comes straight back with no
      # shell evaluation — distinguishing it from a /bin/sh session.
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "cat", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, shell} = Dockd.open_shell(instance)
      assert {:ok, {out, shell}} = Dockd.shell_send(shell, "ping123")
      assert String.contains?(out, "ping123")
      assert :ok = Dockd.close_shell(shell)
    end

    test "explicit shell opt overrides the configured program" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "cat", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, shell} = Dockd.open_shell(instance, shell: ["/bin/sh"])
      assert {:ok, {_, shell}} = Dockd.shell_send(shell, "cd /tmp")
      assert {:ok, {out, shell}} = Dockd.shell_send(shell, "pwd")
      assert String.contains?(out, "/tmp")
      assert :ok = Dockd.close_shell(shell)
    end
  end

  describe "apply/2" do
    test "pulls an image and prepares a running container" do
      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert is_binary(instance.id)
      assert String.starts_with?(instance.name, "dockd-")
      assert instance.image === @image
      assert instance.shell === "/bin/sh"
      assert instance.running? === true
      assert step_results === []
      assert Docker.container_running?(instance.id)
    end

    test "runs setup steps in order and captures their results" do
      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               Dockd.apply(@image,
                 shell: "/bin/sh",
                 steps: [
                   %{step_name: "first", cmd: ["sh", "-lc", "echo first && touch /tmp/first"]},
                   %{step_name: "second", cmd: ["sh", "-lc", "echo second && ls /tmp/first"]}
                 ],
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert Enum.map(step_results, & &1.step_name) === ["first", "second"]
      assert Enum.map(step_results, & &1.exit_code) === [0, 0]
      assert Enum.at(step_results, 0).output === "first\n"
      assert Enum.at(step_results, 1).output === "second\n/tmp/first\n"
    end

    test "returns the partial step_results and the instance when a setup step fails" do
      assert {:error, %Dockd.Error{} = error} =
               Dockd.apply(@image,
                 shell: "/bin/sh",
                 steps: [
                   %{step_name: "first", cmd: ["sh", "-lc", "echo ok"]},
                   %{step_name: "fail", cmd: ["sh", "-lc", "echo nope && exit 7"]},
                   %{step_name: "never", cmd: ["sh", "-lc", "echo never"]}
                 ],
                 instance_name: unique_name()
               )

      if error.instance, do: on_exit(fn -> Dockd.destroy(error.instance) end)

      assert error.phase === :setup
      assert error.exit_code === 7
      assert error.output === "nope\n"

      assert Enum.map(error.step_results, & &1.step_name) === ["first", "fail"]
      assert Enum.map(error.step_results, & &1.exit_code) === [0, 7]
    end

    test "names the replacement when a step still uses the old :label key" do
      spec =
        Dockd.Spec.from_opts(@image,
          instance_name: unique_name(),
          steps: [%{label: "old", cmd: ["true"]}]
        )

      assert {:error, error} = Dockd.apply(spec)

      assert error.phase === :validate
      assert error.message =~ ":label, which was renamed to :step_name"
    end
  end

  describe "apply/2 with :build" do
    @fixtures_dir Path.expand("fixtures", __DIR__)
    @dockerfile Path.join(@fixtures_dir, "Dockerfile")

    test "builds from a Dockerfile path and starts a container" do
      tag = "dockd-test:dockerfile-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(tag,
                 shell: "/bin/sh",
                 build: %{dockerfile: @dockerfile},
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert is_binary(instance.id)
      assert instance.image === tag
      assert Docker.container_running?(instance.id)
    end

    test "passes :args through to the build as --build-arg values" do
      tag = "dockd-test:args-#{System.unique_integer([:positive])}"
      args_dockerfile = Path.join(@fixtures_dir, "Dockerfile.args")

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(tag,
                 shell: "/bin/sh",
                 build: %{
                   dockerfile: args_dockerfile,
                   context: @fixtures_dir,
                   args: %{"GREETING" => "hi-from-args"}
                 },
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, %{output: output, exit_code: 0}} =
               Dockd.shell_command(instance, "cat /tmp/greeting.txt")

      assert String.trim(output) === "hi-from-args"
    end

    test "builds with map-valued :labels without raising on query encoding" do
      tag = "dockd-test:labels-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(tag,
                 shell: "/bin/sh",
                 build: %{dockerfile: @dockerfile, labels: %{"org.test" => "yes"}},
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert instance.image === tag
    end

    test "builds from a directory containing a Dockerfile" do
      tag = "dockd-test:dir-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(tag,
                 shell: "/bin/sh",
                 build: %{dockerfile: @fixtures_dir},
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert is_binary(instance.id)
      assert Docker.container_running?(instance.id)
    end

    test "builds with explicit context directory" do
      tag = "dockd-test:ctx-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(tag,
                 shell: "/bin/sh",
                 build: %{dockerfile: @dockerfile, context: @fixtures_dir},
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert is_binary(instance.id)
      assert Docker.container_running?(instance.id)
    end

    test "runs setup steps on a Dockerfile-built container" do
      tag = "dockd-test:steps-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               Dockd.apply(tag,
                 shell: "/bin/sh",
                 build: %{dockerfile: @dockerfile},
                 steps: [
                   %{step_name: "check built file", cmd: ["cat", "/tmp/built.txt"]}
                 ],
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert [%{step_name: "check built file", exit_code: 0, output: output}] = step_results

      assert String.contains?(output, "built")
    end

    test "returns an error when the dockerfile path does not exist" do
      assert {:error, %Dockd.Error{} = error} =
               Dockd.apply("nope:latest",
                 build: %{dockerfile: "/nonexistent/Dockerfile"},
                 instance_name: unique_name()
               )

      assert error.phase === :validate
      assert error.message =~ "does not exist"
    end

    test "returns an error when directory has no Dockerfile" do
      assert {:error, %Dockd.Error{} = error} =
               Dockd.apply("nope:latest",
                 build: %{dockerfile: System.tmp_dir!()},
                 instance_name: unique_name()
               )

      assert error.phase === :validate
      assert error.message =~ "no Dockerfile found"
    end

    test "returns an error when :build is missing :dockerfile" do
      assert {:error, %Dockd.Error{} = error} =
               Dockd.apply("nope:latest", build: %{nocache: true}, instance_name: unique_name())

      assert error.phase === :validate
      assert error.message =~ ":build map must include a :dockerfile"
    end

    test "container's PID 1 Cmd reflects the configured :shell" do
      tag = "dockd-test:shell-cmd-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(tag,
                 build: %{dockerfile: @dockerfile},
                 shell: "/bin/sh",
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, body} = Docker.find_container(instance.id)
      assert body["Config"]["Cmd"] === ["/bin/sh"]
      assert body["Config"]["Tty"] === true
      assert instance.shell === "/bin/sh"
    end
  end

  describe "destroy/1" do
    test "stops and removes an applied container" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      assert :ok = Dockd.destroy(instance)
      refute Docker.container_running?(instance.id)
      assert {:error, %{status: 404}} = Docker.find_container(instance.id)
    end

    test "accepts a name string and is idempotent on a missing container" do
      assert :ok =
               Dockd.destroy("definitely-not-an-instance-#{System.unique_integer([:positive])}")
    end
  end

  describe "list/1 and get/2 — Docker as source of truth" do
    test "list/0 discovers every applied instance; get/1 round-trips by name" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image,
                 shell: "/bin/sh",
                 instance_name: "list-roundtrip-#{System.unique_integer([:positive])}"
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, instances} = Dockd.list()
      assert Enum.any?(instances, fn i -> i.id === instance.id end)

      assert {:ok, %Instance{} = hydrated} = Dockd.get(instance.name)
      assert hydrated.id === instance.id
      assert hydrated.name === instance.name
      assert hydrated.image === @image
      assert hydrated.shell === "/bin/sh"
      assert hydrated.labels[Instance.marker_label()] === "true"
      assert hydrated.labels[Instance.name_label()] === Dockd.Spec.short_name(instance.name)
    end
  end

  describe "apply/2 with :copy" do
    test "copies a file from the host into the container" do
      tmp =
        Path.join(System.tmp_dir!(), "dockd-copy-host-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      src = Path.join(tmp, "hello.txt")
      File.write!(src, "world")

      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               Dockd.apply(@image,
                 shell: "/bin/sh",
                 copy: [%{src: src, dest: "/etc/app/hello.txt"}],
                 steps: [
                   %{step_name: "read", cmd: ["cat", "/etc/app/hello.txt"]}
                 ],
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert hd(step_results).output === "world"
    end

    test "applies :mode to the copied file" do
      tmp =
        Path.join(System.tmp_dir!(), "dockd-copy-mode-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      src = Path.join(tmp, "secret")
      File.write!(src, "shh")

      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               Dockd.apply(@image,
                 shell: "/bin/sh",
                 copy: [%{src: src, dest: "/root/secret", mode: "0600"}],
                 steps: [
                   %{step_name: "stat", cmd: ["sh", "-lc", "stat -c '%a' /root/secret"]}
                 ],
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert String.trim(hd(step_results).output) === "600"
    end

    test "errors with :validate when :dest is not absolute" do
      assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
               Dockd.apply(@image,
                 copy: [%{src: "/tmp/x", dest: "relative/path"}],
                 instance_name: unique_name()
               )

      assert msg =~ "must be an absolute path"
    end

    test "errors with :copy when :src does not exist" do
      assert {:error, %Dockd.Error{phase: :copy, message: msg} = error} =
               Dockd.apply(@image,
                 shell: "/bin/sh",
                 copy: [%{src: "/does/not/exist", dest: "/tmp/missing"}],
                 instance_name: unique_name()
               )

      if error.instance, do: on_exit(fn -> Dockd.destroy(error.instance) end)
      assert msg =~ "copy source does not exist"
    end
  end

  describe "apply/2 with :disk_mount_enabled" do
    # Use a path that exists locally so validate_source/1 short-circuits with a
    # :validate error after enforce_disk_mount_policy/1 has already emitted its
    # logs - exercising the policy without needing a Docker daemon.
    @local_image "."

    test "default leaves host-exposing options intact and emits no strip log" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
                   Dockd.apply(@local_image,
                     mounts: ["/h:/c"],
                     repos: [%{url: "https://example.invalid/r", dest: "/r"}],
                     copy: [%{src: "/tmp", dest: "/d"}],
                     env: ["LITERAL=value"],
                     instance_name: unique_name()
                   )

          assert msg =~ "local image paths"
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "true is equivalent to default" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.apply(@local_image,
                     disk_mount_enabled: true,
                     mounts: ["/h:/c"],
                     instance_name: unique_name()
                   )
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "false strips :mounts and logs the stripped value" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.apply(@local_image,
                     disk_mount_enabled: false,
                     mounts: ["/h:/c"],
                     instance_name: unique_name()
                   )
        end)

      assert log =~ "disk_mount_enabled=false stripped :mounts"
      assert log =~ "/h:/c"
    end

    test "false strips :repos and :copy with one log per key" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.apply(@local_image,
                     disk_mount_enabled: false,
                     repos: [%{url: "https://example.invalid/r", dest: "/r"}],
                     copy: [%{src: "/tmp", dest: "/d"}],
                     instance_name: unique_name()
                   )
        end)

      assert log =~ "stripped :repos"
      assert log =~ "stripped :copy"
    end

    test "false strips bare-name and tuple :env entries but keeps literals" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.apply(@local_image,
                     disk_mount_enabled: false,
                     env: ["FOO", "BAR=baz", {"QUX", default: "x"}],
                     instance_name: unique_name()
                   )
        end)

      assert log =~ ~s(host-derived :env entry: "FOO")
      assert log =~ ~s(host-derived :env entry: {"QUX")
      refute log =~ ~s(host-derived :env entry: "BAR=baz")
    end

    test "false with only literal :env entries emits no strip log" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.apply(@local_image,
                     disk_mount_enabled: false,
                     env: ["LITERAL=value"],
                     instance_name: unique_name()
                   )
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "false with empty host-exposing lists logs nothing" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.apply(@local_image,
                     disk_mount_enabled: false,
                     mounts: [],
                     repos: [],
                     copy: [],
                     instance_name: unique_name()
                   )
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "non-boolean :disk_mount_enabled is rejected at :validate" do
      assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
               Dockd.apply(@local_image, disk_mount_enabled: "yes", instance_name: unique_name())

      assert msg =~ ":disk_mount_enabled must be a boolean"
    end
  end

  describe "apply/2 with :repos" do
    test "clones a repo on the host and uploads it into the container" do
      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               Dockd.apply(@image,
                 shell: "/bin/sh",
                 repos: [
                   %{
                     url: "https://github.com/octocat/Hello-World.git",
                     dest: "/instance/hello"
                   }
                 ],
                 steps: [
                   %{step_name: "ls", cmd: ["ls", "/instance/hello"]},
                   %{step_name: "no-git", cmd: ["sh", "-lc", "[ ! -d /instance/hello/.git ]"]}
                 ],
                 instance_name: unique_name()
               )

      on_exit(fn -> Dockd.destroy(instance) end)

      assert Enum.map(step_results, & &1.exit_code) === [0, 0]
      assert hd(step_results).output =~ "README"
    end

    test "errors with :validate when :url is missing" do
      assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
               Dockd.apply(@image, repos: [%{dest: "/instance/x"}], instance_name: unique_name())

      assert msg =~ "must include a non-empty :url"
    end

    test "errors with :validate when :dest is not absolute" do
      assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
               Dockd.apply(@image,
                 repos: [%{url: "https://github.com/foo/bar", dest: "rel"}],
                 instance_name: unique_name()
               )

      assert msg =~ "must be an absolute path"
    end
  end

  describe "start/2, stop/2, running?/2" do
    test "stop transitions a running instance to stopped; start brings it back" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, true} = Dockd.running?(instance)
      assert Docker.container_running?(instance.id)

      assert :ok = Dockd.stop(instance)
      assert {:ok, false} = Dockd.running?(instance)
      refute Docker.container_running?(instance.id)

      assert :ok = Dockd.start(instance)
      assert {:ok, true} = Dockd.running?(instance)
      assert Docker.container_running?(instance.id)
    end

    test "start on an already-running instance is :ok" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert :ok = Dockd.start(instance)
      assert {:ok, true} = Dockd.running?(instance)
    end

    test "stop on an already-stopped instance is :ok" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert :ok = Dockd.stop(instance)
      assert :ok = Dockd.stop(instance)
      assert {:ok, false} = Dockd.running?(instance)
    end

    test "accepts a short name as well as a struct" do
      name = "lifecycle-name-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: name)

      on_exit(fn -> Dockd.destroy(instance) end)

      assert :ok = Dockd.stop(name)
      assert {:ok, false} = Dockd.running?(name)
      assert :ok = Dockd.start(name)
      assert {:ok, true} = Dockd.running?(name)
    end
  end

  describe "restart/2" do
    test "stops then starts; container ends up running with a fresh StartedAt" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, before} = Dockd.inspect(instance)
      started_before = get_in(before, ["State", "StartedAt"])

      assert :ok = Dockd.restart(instance)
      assert {:ok, true} = Dockd.running?(instance)

      assert {:ok, after_} = Dockd.inspect(instance)
      started_after = get_in(after_, ["State", "StartedAt"])

      assert is_binary(started_before)
      assert is_binary(started_after)
      assert started_after !== started_before
    end
  end

  describe "logs/2" do
    test "returns the container log binary; :tail and :timestamps pass through" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, logs} = Dockd.logs(instance)
      assert is_binary(logs)

      assert {:ok, tailed} = Dockd.logs(instance, tail: 1, timestamps: true)
      assert is_binary(tailed)
    end

    test "wraps a missing container as an error" do
      assert {:error, _} =
               Dockd.logs("definitely-missing-#{System.unique_integer([:positive])}")
    end
  end

  describe "inspect/2" do
    test "returns the raw Docker inspect payload" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, body} = Dockd.inspect(instance)
      assert body["Id"] === instance.id
      assert is_map(body["State"])
      assert is_map(body["NetworkSettings"])
      assert is_map(body["Config"])
    end

    test "wraps a missing container as a :discover error" do
      assert {:error, %Dockd.Error{phase: :discover}} =
               Dockd.inspect("definitely-missing-#{System.unique_integer([:positive])}")
    end
  end

  describe "refresh/2" do
    test "returns a fresh Instance with current :running? after a stop" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert instance.running? === true
      assert :ok = Dockd.stop(instance)

      assert {:ok, %Instance{} = fresh} = Dockd.refresh(instance)
      assert fresh.id === instance.id
      assert fresh.running? === false
      assert instance.running? === true
    end

    test "accepts a short name" do
      name = "refresh-name-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: name)

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, %Instance{} = fresh} = Dockd.refresh(name)
      assert fresh.id === instance.id
    end
  end

  describe "copy_to/3" do
    test "uploads host files into an existing instance" do
      tmp =
        Path.join(System.tmp_dir!(), "dockd-copy-to-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      src = Path.join(tmp, "greet.txt")
      File.write!(src, "from-copy-to")

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert :ok = Dockd.copy_to(instance, [%{src: src, dest: "/tmp/greet.txt"}])

      assert {:ok, %{output: output, exit_code: 0}} =
               Dockd.shell_command(instance, "cat /tmp/greet.txt")

      assert output =~ "from-copy-to"
    end

    test "surfaces a copy-phase error for a missing source" do
      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(@image, shell: "/bin/sh", instance_name: unique_name())

      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:error, %Dockd.Error{phase: :copy}} =
               Dockd.copy_to(instance, [%{src: "/tmp/dockd-nope", dest: "/tmp/x"}])
    end
  end

  describe "list_temp_files/1, delete_temp_files/1, info/1" do
    test "delete_temp_files clears the staging directory and info reports zero under :temp_files" do
      assert :ok = Dockd.delete_temp_files()
      assert {:ok, []} = Dockd.list_temp_files()

      assert {:ok, %{temp_files: temp_files}} = Dockd.info()
      assert temp_files.count === 0
      assert temp_files.total_bytes === 0
      assert temp_files.oldest_at === nil
      assert temp_files.newest_at === nil
    end
  end

  describe "new_package/2 end to end" do
    test "a scaffolded package can be applied directly" do
      root = scaffold_dir()
      pkg = Path.join(root, unique_name("greeter"))

      assert {:ok, _} =
               Dockd.new_package(pkg,
                 image: "dockd-scaffold-test:#{System.unique_integer([:positive])}",
                 from: @image,
                 shell: "/bin/sh"
               )

      assert {:ok, %ApplyResult{instance: instance}} = Dockd.apply_package(pkg)
      on_exit(fn -> Dockd.destroy(instance) end)

      assert {:ok, %{exit_code: 0}} = Dockd.shell_command(instance, ["true"])
    end

    test "a scaffolded package set installs and applies by name" do
      root = scaffold_dir()
      dest = Path.join(root, "installed")
      name = unique_name("greeter")

      assert {:ok, _} =
               Dockd.new_package(Path.join([root, "src", "packages", name]),
                 image: "dockd-scaffold-set:#{System.unique_integer([:positive])}",
                 dockerfile: "FROM #{@image}\nRUN echo scaffolded > /etc/greeting\n",
                 shell: "/bin/sh",
                 steps: [%{step_name: "verify", cmd: ["sh", "-c", "test -f /etc/greeting"]}]
               )

      assert {:ok, [^name]} = Dockd.install_packages(Path.join(root, "src"), dest_dir: dest)

      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               Dockd.apply_package(name, packages_path: dest)

      on_exit(fn -> Dockd.destroy(instance) end)

      assert Enum.map(step_results, & &1.step_name) === ["verify"]

      assert {:ok, %{output: output, exit_code: 0}} =
               Dockd.shell_command(instance, "cat /etc/greeting")

      assert String.trim(output) === "scaffolded"
    end
  end

  defp unique_name(prefix \\ "test") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp scaffold_dir do
    dir = Path.join(System.tmp_dir!(), unique_name("dockd-scaffold"))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
