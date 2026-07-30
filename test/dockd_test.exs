defmodule DockdTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Dockd.ApplyResult
  alias Dockd.Instance

  @image "busybox:1.37.0"

  describe "shell_command/2" do
    test "runs a string command and returns combined output with exit code" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, %{output: "hello\n", exit_code: 0}} =
               Dockd.shell_command(instance, "echo hello", endpoint())
    end

    test "runs an argv list verbatim and surfaces non-zero exit codes" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, %{exit_code: 0}} = Dockd.shell_command(instance, ["true"], endpoint())

      assert {:ok, %{exit_code: code}} =
               Dockd.shell_command(instance, ["sh", "-c", "exit 3"], endpoint())

      assert code === 3
    end
  end

  describe "open_shell / shell_send / close_shell" do
    test "persistent shell preserves state between commands" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, shell} = Dockd.open_shell(instance, endpoint())
      assert {:ok, {_, shell}} = Dockd.shell_send(shell, "cd /tmp")
      assert {:ok, {out, shell}} = Dockd.shell_send(shell, "pwd")
      assert String.contains?(out, "/tmp")
      assert :ok = Dockd.close_shell(shell)
    end

    test "defaults the session program to the instance's configured shell" do
      # "cat" echoes stdin verbatim, so a line sent comes straight back with no
      # shell evaluation — distinguishing it from a /bin/sh session.
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "cat")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, shell} = Dockd.open_shell(instance, endpoint())
      assert {:ok, {out, shell}} = Dockd.shell_send(shell, "ping123")
      assert String.contains?(out, "ping123")
      assert :ok = Dockd.close_shell(shell)
    end

    test "explicit shell opt overrides the configured program" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "cat")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, shell} = Dockd.open_shell(instance, endpoint(), shell: ["/bin/sh"])
      assert {:ok, {_, shell}} = Dockd.shell_send(shell, "cd /tmp")
      assert {:ok, {out, shell}} = Dockd.shell_send(shell, "pwd")
      assert String.contains?(out, "/tmp")
      assert :ok = Dockd.close_shell(shell)
    end

    # shell_send/3 used to answer {:error, {reason, handle}}. It now returns the
    # same {:error, %ErrorMessage{}} as everything else, so the handle — which the
    # caller still needs in order to close the session — moved to details.shell.
    test "sending to a closed shell reports an ErrorMessage carrying the handle" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, shell} = Dockd.open_shell(instance, endpoint())
      assert :ok = Dockd.close_shell(shell)

      assert {:error, %ErrorMessage{details: details}} = Dockd.shell_send(shell, "pwd")
      assert Map.has_key?(details, :shell)
      assert :ok = Dockd.close_shell(details.shell)
    end
  end

  describe "apply/2" do
    test "pulls an image and prepares a running container" do
      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

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
               create(@image, unique_name(),
                 shell: "/bin/sh",
                 steps: [
                   %{step_name: "first", cmd: ["sh", "-lc", "echo first && touch /tmp/first"]},
                   %{step_name: "second", cmd: ["sh", "-lc", "echo second && ls /tmp/first"]}
                 ]
               )

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert Enum.map(step_results, & &1.step_name) === ["first", "second"]
      assert Enum.map(step_results, & &1.exit_code) === [0, 0]
      assert Enum.at(step_results, 0).output === "first\n"
      assert Enum.at(step_results, 1).output === "second\n/tmp/first\n"
    end

    test "returns the partial step_results and the instance when a setup step fails" do
      assert {:error, %ErrorMessage{} = error} =
               create(@image, unique_name(),
                 shell: "/bin/sh",
                 steps: [
                   %{step_name: "first", cmd: ["sh", "-lc", "echo ok"]},
                   %{step_name: "fail", cmd: ["sh", "-lc", "echo nope && exit 7"]},
                   %{step_name: "never", cmd: ["sh", "-lc", "echo never"]}
                 ]
               )

      assert error.code === :unprocessable_entity
      assert error.details.phase === :setup
      assert error.details.exit_code === 7
      assert error.details.output === "nope\n"

      assert Enum.map(error.details.step_results, & &1.step_name) === ["first", "fail"]
      assert Enum.map(error.details.step_results, & &1.exit_code) === [0, 7]

      # The cleanup contract: details.instance is the whole reason a failed apply
      # does not leak a container, so prove it actually destroys.
      assert %Dockd.Instance{} = instance = error.details.instance
      assert :ok = Dockd.destroy(instance, endpoint())
      assert {:error, %ErrorMessage{code: :not_found}} = Dockd.get(instance.name, endpoint())
    end

    test "a Docker-originated failure keeps the raw reason in details" do
      assert {:error, %ErrorMessage{} = error} =
               create("definitely-not-a-real-image:nope", unique_name(), shell: "/bin/sh")

      assert error.code === :bad_gateway
      assert error.details.phase === :pull
      # Verbatim, so a caller can match on it rather than parse the message.
      assert Map.has_key?(error.details, :reason)
    end

    test "names the replacement when a step still uses the old :label key" do
      {:ok, spec} =
        Dockd.Spec.new(@image, unique_name(), steps: [%{label: "old", cmd: ["true"]}])

      assert {:error, error} = Dockd.apply(spec, endpoint(), true, %{}, temp_root())

      assert error.details.phase === :validate
      assert error.message =~ ":label, which was renamed to :step_name"
    end
  end

  describe "apply/2 with :build" do
    @fixtures_dir Path.expand("fixtures", __DIR__)
    @dockerfile Path.join(@fixtures_dir, "Dockerfile")

    test "builds from a Dockerfile path and starts a container" do
      tag = "dockd-test:dockerfile-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               create(tag, unique_name(), shell: "/bin/sh", build: %{dockerfile: @dockerfile})

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert is_binary(instance.id)
      assert instance.image === tag
      assert Docker.container_running?(instance.id)
    end

    test "passes :args through to the build as --build-arg values" do
      tag = "dockd-test:args-#{System.unique_integer([:positive])}"
      args_dockerfile = Path.join(@fixtures_dir, "Dockerfile.args")

      assert {:ok, %ApplyResult{instance: instance}} =
               create(tag, unique_name(),
                 shell: "/bin/sh",
                 build: %{
                   dockerfile: args_dockerfile,
                   context: @fixtures_dir,
                   args: %{"GREETING" => "hi-from-args"}
                 }
               )

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, %{output: output, exit_code: 0}} =
               Dockd.shell_command(instance, "cat /tmp/greeting.txt", endpoint())

      assert String.trim(output) === "hi-from-args"
    end

    test "builds with map-valued :labels without raising on query encoding" do
      tag = "dockd-test:labels-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               create(tag, unique_name(),
                 shell: "/bin/sh",
                 build: %{dockerfile: @dockerfile, labels: %{"org.test" => "yes"}}
               )

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert instance.image === tag
    end

    test "builds from a directory containing a Dockerfile" do
      tag = "dockd-test:dir-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               create(tag, unique_name(), shell: "/bin/sh", build: %{dockerfile: @fixtures_dir})

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert is_binary(instance.id)
      assert Docker.container_running?(instance.id)
    end

    test "builds with explicit context directory" do
      tag = "dockd-test:ctx-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               create(tag, unique_name(),
                 shell: "/bin/sh",
                 build: %{dockerfile: @dockerfile, context: @fixtures_dir}
               )

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert is_binary(instance.id)
      assert Docker.container_running?(instance.id)
    end

    test "runs setup steps on a Dockerfile-built container" do
      tag = "dockd-test:steps-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               create(tag, unique_name(),
                 shell: "/bin/sh",
                 build: %{dockerfile: @dockerfile},
                 steps: [%{step_name: "check built file", cmd: ["cat", "/tmp/built.txt"]}]
               )

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert [%{step_name: "check built file", exit_code: 0, output: output}] = step_results

      assert String.contains?(output, "built")
    end

    test "returns an error when the dockerfile path does not exist" do
      assert {:error, %ErrorMessage{} = error} =
               create("nope:latest", unique_name(),
                 build: %{dockerfile: "/nonexistent/Dockerfile"}
               )

      assert error.details.phase === :validate
      assert error.message =~ "does not exist"
    end

    test "returns an error when directory has no Dockerfile" do
      assert {:error, %ErrorMessage{} = error} =
               create("nope:latest", unique_name(), build: %{dockerfile: System.tmp_dir!()})

      assert error.details.phase === :validate
      assert error.message =~ "no Dockerfile found"
    end

    test "returns an error when :build is missing :dockerfile" do
      assert {:error, %ErrorMessage{} = error} =
               create("nope:latest", unique_name(), build: %{nocache: true})

      assert error.details.phase === :validate
      assert error.message =~ ":build map must include a :dockerfile"
    end

    test "container's PID 1 Cmd reflects the configured :shell" do
      tag = "dockd-test:shell-cmd-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               create(tag, unique_name(), build: %{dockerfile: @dockerfile}, shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, body} = Docker.find_container(instance.id)
      assert body["Config"]["Cmd"] === ["/bin/sh"]
      assert body["Config"]["Tty"] === true
      assert instance.shell === "/bin/sh"
    end
  end

  describe "destroy/1" do
    test "stops and removes an applied container" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      assert :ok = Dockd.destroy(instance, endpoint())
      refute Docker.container_running?(instance.id)
      assert {:error, %{status: 404}} = Docker.find_container(instance.id)
    end

    test "accepts a name string and is idempotent on a missing container" do
      assert :ok =
               Dockd.destroy(
                 "definitely-not-an-instance-#{System.unique_integer([:positive])}",
                 endpoint()
               )
    end
  end

  describe "list/1 and get/2 — Docker as source of truth" do
    test "list/0 discovers every applied instance; get/1 round-trips by name" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, "list-roundtrip-#{System.unique_integer([:positive])}",
                 shell: "/bin/sh"
               )

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, instances} = Dockd.list(endpoint())
      assert Enum.any?(instances, fn i -> i.id === instance.id end)

      assert {:ok, %Instance{} = hydrated} = Dockd.get(instance.name, endpoint())
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
               create(@image, unique_name(),
                 shell: "/bin/sh",
                 copy: [%{src: src, dest: "/etc/app/hello.txt"}],
                 steps: [%{step_name: "read", cmd: ["cat", "/etc/app/hello.txt"]}]
               )

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert hd(step_results).output === "world"
    end

    # The shapes an in-process `:erl_tar` archive has to carry that a single file
    # does not: nested directories, an empty directory, a symlink, and a
    # permission bit that must survive the round trip.
    test "copies a directory tree, preserving nesting, empty dirs, links and modes" do
      tmp =
        Path.join(System.tmp_dir!(), "dockd-copy-tree-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp, "tree/nested"))
      File.mkdir_p!(Path.join(tmp, "tree/empty"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      File.write!(Path.join(tmp, "tree/nested/deep.txt"), "deep")
      File.write!(Path.join(tmp, "tree/locked"), "shh")
      File.chmod!(Path.join(tmp, "tree/locked"), 0o600)
      File.ln_s!("nested/deep.txt", Path.join(tmp, "tree/link"))

      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               create(@image, unique_name(),
                 shell: "/bin/sh",
                 copy: [%{src: Path.join(tmp, "tree"), dest: "/opt/tree"}],
                 steps: [
                   %{
                     step_name: "inspect tree",
                     cmd: [
                       "sh",
                       "-lc",
                       "echo \"nested=$(cat /opt/tree/nested/deep.txt)\"; " <>
                         "[ -d /opt/tree/empty ] && echo empty-dir; " <>
                         "echo \"link=$(cat /opt/tree/link)\"; " <>
                         "echo \"mode=$(stat -c '%a' /opt/tree/locked)\""
                     ]
                   }
                 ]
               )

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert hd(step_results).output === "nested=deep\nempty-dir\nlink=deep\nmode=600\n"
    end

    test "applies :mode to the copied file" do
      tmp =
        Path.join(System.tmp_dir!(), "dockd-copy-mode-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      src = Path.join(tmp, "secret")
      File.write!(src, "shh")

      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               create(@image, unique_name(),
                 shell: "/bin/sh",
                 copy: [%{src: src, dest: "/root/secret", mode: "0600"}],
                 steps: [%{step_name: "stat", cmd: ["sh", "-lc", "stat -c '%a' /root/secret"]}]
               )

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert String.trim(hd(step_results).output) === "600"
    end

    test "errors with :validate when :dest is not absolute" do
      assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} =
               create(@image, unique_name(), copy: [%{src: "/tmp/x", dest: "relative/path"}])

      assert msg =~ "must be an absolute path"
    end

    test "errors with :copy when :src does not exist" do
      assert {:error, %ErrorMessage{message: msg, details: %{phase: :copy}} = error} =
               create(@image, unique_name(),
                 shell: "/bin/sh",
                 copy: [%{src: "/does/not/exist", dest: "/tmp/missing"}]
               )

      if error.details.instance, do: on_exit(fn -> Dockd.destroy(error.details.instance, endpoint()) end)
      assert msg =~ "copy source does not exist"
    end
  end

  describe "disk_mount_enabled policy" do
    # Uses a path that exists locally so validate_source/1 short-circuits with a
    # :validate error after enforce_disk_mount_policy/2 has already emitted its
    # logs — exercising the policy without needing a Docker daemon.
    @local_image "."

    test "true leaves host-exposing options intact and emits no strip log" do
      log =
        capture_log(fn ->
          assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} =
                   create_with(@local_image, true,
                     mounts: ["/h:/c"],
                     copy: [%{src: "/tmp", dest: "/d"}],
                     env: ["LITERAL=value"]
                   )

          assert msg =~ "local image paths"
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "false strips :mounts and logs the stripped value" do
      log =
        capture_log(fn ->
          assert {:error, %ErrorMessage{details: %{phase: :validate}}} =
                   create_with(@local_image, false, mounts: ["/h:/c"])
        end)

      assert log =~ "disk_mount_enabled=false stripped :mounts"
      assert log =~ "/h:/c"
    end

    test "false strips :copy and logs the stripped value" do
      log =
        capture_log(fn ->
          assert {:error, %ErrorMessage{details: %{phase: :validate}}} =
                   create_with(@local_image, false, copy: [%{src: "/tmp", dest: "/d"}])
        end)

      assert log =~ "stripped :copy"
    end

    test "false strips bare-name :env entries but keeps literals" do
      log =
        capture_log(fn ->
          assert {:error, %ErrorMessage{details: %{phase: :validate}}} =
                   create_with(@local_image, false, env: ["FOO", "BAR=baz"])
        end)

      assert log =~ ~s(host-derived :env entry: "FOO")
      refute log =~ ~s(host-derived :env entry: "BAR=baz")
    end

    test "false with only literal :env entries emits no strip log" do
      log =
        capture_log(fn ->
          assert {:error, %ErrorMessage{details: %{phase: :validate}}} =
                   create_with(@local_image, false, env: ["LITERAL=value"])
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "false with empty host-exposing lists logs nothing" do
      log =
        capture_log(fn ->
          assert {:error, %ErrorMessage{details: %{phase: :validate}}} =
                   create_with(@local_image, false, mounts: [], copy: [])
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    # There is no clause that accepts a non-boolean, and in particular none that
    # reads an absent value as permission to expose the host.
    test "a non-boolean disk_mount_enabled is rejected at :validate" do
      for bad <- ["yes", nil, 1] do
        assert {:error, %ErrorMessage{message: msg, details: %{phase: :validate}}} =
                 create_with(@local_image, bad, [])

        assert msg =~ "disk_mount_enabled must be a boolean"
      end
    end
  end

  describe "start/2, stop/2, running?/2" do
    test "stop transitions a running instance to stopped; start brings it back" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, true} = Dockd.running?(instance, endpoint())
      assert Docker.container_running?(instance.id)

      assert :ok = Dockd.stop(instance, endpoint())
      assert {:ok, false} = Dockd.running?(instance, endpoint())
      refute Docker.container_running?(instance.id)

      assert :ok = Dockd.start(instance, endpoint())
      assert {:ok, true} = Dockd.running?(instance, endpoint())
      assert Docker.container_running?(instance.id)
    end

    test "start on an already-running instance is :ok" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert :ok = Dockd.start(instance, endpoint())
      assert {:ok, true} = Dockd.running?(instance, endpoint())
    end

    test "stop on an already-stopped instance is :ok" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert :ok = Dockd.stop(instance, endpoint())
      assert :ok = Dockd.stop(instance, endpoint())
      assert {:ok, false} = Dockd.running?(instance, endpoint())
    end

    test "accepts a short name as well as a struct" do
      name = "lifecycle-name-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, name, shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert :ok = Dockd.stop(name, endpoint())
      assert {:ok, false} = Dockd.running?(name, endpoint())
      assert :ok = Dockd.start(name, endpoint())
      assert {:ok, true} = Dockd.running?(name, endpoint())
    end
  end

  describe "restart/2" do
    test "stops then starts; container ends up running with a fresh StartedAt" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, before} = Dockd.inspect(instance, endpoint())
      started_before = get_in(before, ["State", "StartedAt"])

      assert :ok = Dockd.restart(instance, endpoint())
      assert {:ok, true} = Dockd.running?(instance, endpoint())

      assert {:ok, after_} = Dockd.inspect(instance, endpoint())
      started_after = get_in(after_, ["State", "StartedAt"])

      assert is_binary(started_before)
      assert is_binary(started_after)
      assert started_after !== started_before
    end
  end

  describe "running?/3" do
    # Unlike logs/2 and inspect/3, an unknown name is not an error here: the
    # question "is it running" has a truthful answer for a container that does
    # not exist, and callers use it to branch before deciding to create one.
    test "reports false for a container that does not exist" do
      assert {:ok, false} =
               Dockd.running?("definitely-missing-#{System.unique_integer([:positive])}", endpoint())
    end

    test "reports false after the instance is destroyed" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      assert {:ok, true} = Dockd.running?(instance, endpoint())

      assert :ok = Dockd.destroy(instance, endpoint())
      assert {:ok, false} = Dockd.running?(instance, endpoint())
    end
  end

  describe "logs/2" do
    test "returns the container log binary; :tail and :timestamps pass through" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, logs} = Dockd.logs(instance, endpoint())
      assert is_binary(logs)

      assert {:ok, tailed} = Dockd.logs(instance, endpoint(), tail: 1, timestamps: true)
      assert is_binary(tailed)
    end

    test "wraps a missing container as an error" do
      assert {:error, _} =
               Dockd.logs("definitely-missing-#{System.unique_integer([:positive])}", endpoint())
    end
  end

  describe "inspect/2" do
    test "returns the raw Docker inspect payload" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, body} = Dockd.inspect(instance, endpoint())
      assert body["Id"] === instance.id
      assert is_map(body["State"])
      assert is_map(body["NetworkSettings"])
      assert is_map(body["Config"])
    end

    test "wraps a missing container as a :discover error" do
      assert {:error, %ErrorMessage{details: %{phase: :discover}}} =
               Dockd.inspect(
                 "definitely-missing-#{System.unique_integer([:positive])}",
                 endpoint()
               )
    end
  end

  describe "refresh/2" do
    test "returns a fresh Instance with current :running? after a stop" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert instance.running? === true
      assert :ok = Dockd.stop(instance, endpoint())

      assert {:ok, %Instance{} = fresh} = Dockd.refresh(instance, endpoint())
      assert fresh.id === instance.id
      assert fresh.running? === false
      assert instance.running? === true
    end

    test "accepts a short name" do
      name = "refresh-name-#{System.unique_integer([:positive])}"

      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, name, shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:ok, %Instance{} = fresh} = Dockd.refresh(name, endpoint())
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
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert :ok =
               Dockd.copy_to(
                 instance,
                 [%{src: src, dest: "/tmp/greet.txt"}],
                 temp_root(),
                 endpoint()
               )

      assert {:ok, %{output: output, exit_code: 0}} =
               Dockd.shell_command(instance, "cat /tmp/greet.txt", endpoint())

      assert output =~ "from-copy-to"
    end

    test "surfaces a copy-phase error for a missing source" do
      assert {:ok, %ApplyResult{instance: instance}} =
               create(@image, unique_name(), shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert {:error, %ErrorMessage{details: %{phase: :copy}}} =
               Dockd.copy_to(
                 instance,
                 [%{src: "/tmp/dockd-nope", dest: "/tmp/x"}],
                 temp_root(),
                 endpoint()
               )
    end
  end

  describe "list_temp_files/1, delete_temp_files/1" do
    test "delete_temp_files clears the named root" do
      root = host_dir()
      File.mkdir_p!(Path.join(root, "dockd-copy-1"))
      File.write!(Path.join([root, "dockd-copy-1", "staged"]), "leftover")

      assert {:ok, [_]} = Dockd.list_temp_files(root)

      assert :ok = Dockd.delete_temp_files(root)
      assert {:ok, []} = Dockd.list_temp_files(root)

      # The root itself survives a sweep of its children.
      assert File.dir?(root)
    end

    # This deletes recursively, so a root the caller never named is refused.
    test "refuses a root that would sweep too much" do
      assert {:error, %ErrorMessage{}} = Dockd.delete_temp_files("/")
      assert {:error, %ErrorMessage{}} = Dockd.delete_temp_files("")
      assert {:error, %ErrorMessage{}} = Dockd.delete_temp_files("relative/dir")
    end
  end

  describe "Spec.from_map/1 end to end" do
    test "a spec map is applied and the container runs" do
      name = unique_name("mapped")

      assert {:ok, spec} =
               Dockd.Spec.from_map(%{
                 instance_name: name,
                 image: @image,
                 shell: "/bin/sh",
                 env: ["GREETING=hello"],
                 steps: [%{step_name: "verify", cmd: ["true"]}]
               })

      assert {:ok, %ApplyResult{instance: instance, step_results: step_results}} =
               Dockd.apply(spec, endpoint(), false, %{}, temp_root())

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert Enum.map(step_results, & &1.step_name) === ["verify"]

      assert {:ok, %{output: output, exit_code: 0}} =
               Dockd.shell_command(instance, "echo $GREETING", endpoint())

      assert String.trim(output) === "hello"
    end

    # The spec keys are atoms; a Docker *label* is a string on both sides, so a
    # package's :labels map is carried through untouched.
    test "a package's :labels reach the container as written" do
      assert {:ok, spec} =
               Dockd.Spec.from_map(%{
                 instance_name: unique_name("frompkg"),
                 image: @image,
                 shell: "/bin/sh",
                 labels: %{"team" => "platform"}
               })

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(spec, endpoint(), false, %{}, temp_root())

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert instance.labels["team"] === "platform"
      assert {:ok, %{exit_code: 0}} = Dockd.shell_command(instance, ["true"], endpoint())
    end

    # A package that builds its own image still works — the caller absolutizes
    # the Dockerfile path, which is the only thing the package loader used to do.
    test "a spec map that builds its own image works with an absolute build path" do
      tag = "dockd-test:from-map-#{System.unique_integer([:positive])}"

      assert {:ok, spec} =
               Dockd.Spec.from_map(%{
                 instance_name: unique_name("built"),
                 image: tag,
                 shell: "/bin/sh",
                 build: %{dockerfile: @dockerfile}
               })

      assert {:ok, %ApplyResult{instance: instance}} =
               Dockd.apply(spec, endpoint(), false, %{}, temp_root())

      on_exit(fn -> Dockd.destroy(instance, endpoint()) end)

      assert instance.image === tag
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  #
  # dockd itself reads nothing from the environment, so the suite has to decide
  # what to pass. A test *may* discover these — that is the point of the change:
  # the choice is visible here rather than buried in the library.
  # ---------------------------------------------------------------------------

  defp endpoint do
    System.get_env("DOCKD_TEST_ENDPOINT") || "unix:///var/run/docker.sock"
  end

  defp temp_root, do: System.tmp_dir!()

  defp create(image, instance_name, opts) do
    create_with(image, instance_name, true, opts)
  end

  # Arity-3 form used by the disk-mount tests, where the policy is the variable
  # under test and the name does not matter.
  defp create_with(image, disk_mount_enabled, opts) when is_list(opts) do
    create_with(image, unique_name(), disk_mount_enabled, opts)
  end

  defp create_with(image, instance_name, disk_mount_enabled, opts) do
    Dockd.apply_image(
      image,
      instance_name,
      endpoint(),
      disk_mount_enabled,
      host_env(),
      temp_root(),
      opts
    )
  end

  # An explicit slice of the host environment, rather than all of it.
  defp host_env do
    ~w(HOME PATH USER)
    |> Enum.flat_map(fn name ->
      case System.fetch_env(name) do
        {:ok, value} -> [{name, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp unique_name(prefix \\ "test") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  # A throwaway host directory, torn down when the test ends.
  defp host_dir do
    dir = Path.join(System.tmp_dir!(), unique_name("dockd-test"))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
