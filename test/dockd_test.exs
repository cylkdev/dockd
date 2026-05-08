defmodule DockdTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @image "busybox:1.37.0"

  describe "shell_command/1" do
    test "uses container name and requested shell" do
      session = %Dockd.Session{container_name: "dockd-shell", shell: "/bin/bash"}

      assert Dockd.shell_command(session) == "docker exec -it dockd-shell /bin/bash"
    end
  end

  describe "prepare/2" do
    test "pulls an image, prepares a container, and returns an interactive shell command" do
      assert {:ok, session} = Dockd.prepare(@image)
      on_exit(fn -> Dockd.destroy(session) end)

      assert is_binary(session.container_id)
      assert String.starts_with?(session.container_name, "dockd-")
      assert session.image == @image
      assert session.shell == "/bin/sh"
      assert session.shell_command == "docker exec -it #{session.container_name} /bin/sh"
      assert session.step_results == []
      assert Docker.container_running?(session.container_id)
    end

    test "runs setup steps in order and captures their results" do
      assert {:ok, session} =
               Dockd.prepare(@image,
                 steps: [
                   %{label: "first", cmd: ["sh", "-lc", "echo first && touch /tmp/first"]},
                   %{label: "second", cmd: ["sh", "-lc", "echo second && ls /tmp/first"]}
                 ]
               )

      on_exit(fn -> Dockd.destroy(session) end)

      assert Enum.map(session.step_results, & &1.label) == ["first", "second"]
      assert Enum.map(session.step_results, & &1.exit_code) == [0, 0]
      assert Enum.at(session.step_results, 0).output == "first\n"
      assert Enum.at(session.step_results, 1).output == "second\n/tmp/first\n"
    end

    test "returns a partial session when a setup step fails" do
      assert {:error, %Dockd.Error{} = error} =
               Dockd.prepare(@image,
                 steps: [
                   %{label: "first", cmd: ["sh", "-lc", "echo ok"]},
                   %{label: "fail", cmd: ["sh", "-lc", "echo nope && exit 7"]},
                   %{label: "never", cmd: ["sh", "-lc", "echo never"]}
                 ]
               )

      if error.session do
        on_exit(fn -> Dockd.destroy(error.session) end)
      end

      assert error.phase == :setup
      assert error.exit_code == 7
      assert error.output == "nope\n"

      assert error.session.shell_command ==
               "docker exec -it #{error.session.container_name} /bin/sh"

      assert Enum.map(error.session.step_results, & &1.label) == ["first", "fail"]
      assert Enum.map(error.session.step_results, & &1.exit_code) == [0, 7]
    end
  end

  describe "prepare/2 with :build" do
    @fixtures_dir Path.expand("fixtures", __DIR__)
    @dockerfile Path.join(@fixtures_dir, "Dockerfile")

    test "builds from a Dockerfile path and starts a container" do
      tag = "dockd-test:dockerfile-#{System.unique_integer([:positive])}"

      assert {:ok, session} = Dockd.prepare(tag, build: %{dockerfile: @dockerfile})
      on_exit(fn -> Dockd.destroy(session) end)

      assert is_binary(session.container_id)
      assert session.image == tag
      assert Docker.container_running?(session.container_id)
    end

    test "builds from a directory containing a Dockerfile" do
      tag = "dockd-test:dir-#{System.unique_integer([:positive])}"

      assert {:ok, session} = Dockd.prepare(tag, build: %{dockerfile: @fixtures_dir})
      on_exit(fn -> Dockd.destroy(session) end)

      assert is_binary(session.container_id)
      assert Docker.container_running?(session.container_id)
    end

    test "builds with explicit context directory" do
      tag = "dockd-test:ctx-#{System.unique_integer([:positive])}"

      assert {:ok, session} =
               Dockd.prepare(tag,
                 build: %{dockerfile: @dockerfile, context: @fixtures_dir}
               )

      on_exit(fn -> Dockd.destroy(session) end)

      assert is_binary(session.container_id)
      assert Docker.container_running?(session.container_id)
    end

    test "runs setup steps on a Dockerfile-built container" do
      tag = "dockd-test:steps-#{System.unique_integer([:positive])}"

      assert {:ok, session} =
               Dockd.prepare(tag,
                 build: %{dockerfile: @dockerfile},
                 steps: [
                   %{label: "check built file", cmd: ["cat", "/tmp/built.txt"]}
                 ]
               )

      on_exit(fn -> Dockd.destroy(session) end)

      assert [%{label: "check built file", exit_code: 0, output: output}] =
               session.step_results

      assert String.contains?(output, "built")
    end

    test "returns an error when the dockerfile path does not exist" do
      assert {:error, %Dockd.Error{} = error} =
               Dockd.prepare("nope:latest",
                 build: %{dockerfile: "/nonexistent/Dockerfile"}
               )

      assert error.phase == :validate
      assert error.message =~ "does not exist"
    end

    test "returns an error when directory has no Dockerfile" do
      assert {:error, %Dockd.Error{} = error} =
               Dockd.prepare("nope:latest", build: %{dockerfile: System.tmp_dir!()})

      assert error.phase == :validate
      assert error.message =~ "no Dockerfile found"
    end

    test "returns an error when :build is missing :dockerfile" do
      assert {:error, %Dockd.Error{} = error} =
               Dockd.prepare("nope:latest", build: %{nocache: true})

      assert error.phase == :validate
      assert error.message =~ ":build map must include a :dockerfile"
    end

    test "container's PID 1 Cmd reflects the configured :shell" do
      tag = "dockd-test:shell-cmd-#{System.unique_integer([:positive])}"

      assert {:ok, session} =
               Dockd.prepare(tag, build: %{dockerfile: @dockerfile}, shell: "/bin/sh")

      on_exit(fn -> Dockd.destroy(session) end)

      assert {:ok, body} = Docker.find_container(session.container_id)
      assert body["Config"]["Cmd"] == ["/bin/sh"]
      assert body["Config"]["Tty"] == true
    end

    test "container's PID 1 defaults to /bin/sh when :shell is not provided" do
      tag = "dockd-test:shell-default-#{System.unique_integer([:positive])}"

      assert {:ok, session} = Dockd.prepare(tag, build: %{dockerfile: @dockerfile})
      on_exit(fn -> Dockd.destroy(session) end)

      assert {:ok, body} = Docker.find_container(session.container_id)
      assert body["Config"]["Cmd"] == ["/bin/sh"]
      assert body["Config"]["Tty"] == true
    end
  end

  describe "Dockd.Package.load/1 build path resolution" do
    @fixtures_dockerfile Path.expand("fixtures/Dockerfile", __DIR__)

    test "resolves a relative :build dockerfile path against the package file's directory" do
      assert {:ok, {image, opts}} =
               Dockd.Package.load("test/fixtures/packages/with_build.json")

      assert image == "dockd-test:rel-build"
      build = Keyword.fetch!(opts, :build)
      dockerfile = Map.fetch!(build, :dockerfile)

      assert Path.type(dockerfile) == :absolute
      assert dockerfile == @fixtures_dockerfile
    end

    test "leaves an absolute :build dockerfile path untouched" do
      tmp = Path.join(System.tmp_dir!(), "dockd-pkg-abs-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      pkg_path = Path.join(tmp, "abs.json")
      absolute_dockerfile = "/absolute/path/Foo"

      File.write!(pkg_path, """
      {
        "image": "dockd-test:abs",
        "build": { "dockerfile": "#{absolute_dockerfile}" }
      }
      """)

      assert {:ok, {_image, opts}} = Dockd.Package.load(pkg_path)
      build = Keyword.fetch!(opts, :build)
      assert Map.fetch!(build, :dockerfile) == absolute_dockerfile
    end

    test "resolves a relative :build context path against the package file's directory" do
      tmp = Path.join(System.tmp_dir!(), "dockd-pkg-ctx-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      pkg_path = Path.join(tmp, "ctx.json")

      File.write!(pkg_path, """
      {
        "image": "dockd-test:ctx",
        "build": { "dockerfile": "Dockerfile", "context": "./sub" }
      }
      """)

      assert {:ok, {_image, opts}} = Dockd.Package.load(pkg_path)
      build = Keyword.fetch!(opts, :build)
      assert Map.fetch!(build, :dockerfile) == Path.join(tmp, "Dockerfile")
      assert Map.fetch!(build, :context) == Path.join(tmp, "sub")
    end
  end

  describe "destroy/1" do
    test "stops and removes a prepared container" do
      assert {:ok, session} = Dockd.prepare(@image)

      assert :ok = Dockd.destroy(session)
      refute Docker.container_running?(session.container_id)
      assert {:error, %{status: 404}} = Docker.find_container(session.container_id)
    end
  end

  describe "prepare/2 with :copy" do
    test "copies a file from the host into the container" do
      tmp =
        Path.join(System.tmp_dir!(), "dockd-copy-host-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      src = Path.join(tmp, "hello.txt")
      File.write!(src, "world")

      assert {:ok, session} =
               Dockd.prepare(@image,
                 copy: [%{src: src, dest: "/etc/app/hello.txt"}],
                 steps: [
                   %{label: "read", cmd: ["cat", "/etc/app/hello.txt"]}
                 ]
               )

      on_exit(fn -> Dockd.destroy(session) end)

      assert hd(session.step_results).output == "world"
    end

    test "applies :mode to the copied file" do
      tmp =
        Path.join(System.tmp_dir!(), "dockd-copy-mode-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      src = Path.join(tmp, "secret")
      File.write!(src, "shh")

      assert {:ok, session} =
               Dockd.prepare(@image,
                 copy: [%{src: src, dest: "/root/secret", mode: "0600"}],
                 steps: [
                   %{label: "stat", cmd: ["sh", "-lc", "stat -c '%a' /root/secret"]}
                 ]
               )

      on_exit(fn -> Dockd.destroy(session) end)

      assert String.trim(hd(session.step_results).output) == "600"
    end

    test "errors with :validate when :dest is not absolute" do
      assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
               Dockd.prepare(@image, copy: [%{src: "/tmp/x", dest: "relative/path"}])

      assert msg =~ "must be an absolute path"
    end

    test "errors with :copy when :src does not exist" do
      assert {:error, %Dockd.Error{phase: :copy, message: msg} = error} =
               Dockd.prepare(@image,
                 copy: [%{src: "/does/not/exist", dest: "/tmp/missing"}]
               )

      if error.session, do: on_exit(fn -> Dockd.destroy(error.session) end)
      assert msg =~ "copy source does not exist"
    end
  end

  describe "prepare/2 with :disk_mount_enabled" do
    # Use a path that exists locally so validate_source/3 short-circuits with a
    # :validate error after enforce_disk_mount_policy/1 has already emitted its
    # logs - exercising the policy without needing a Docker daemon.
    @local_image "."

    test "default leaves host-exposing options intact and emits no strip log" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
                   Dockd.prepare(@local_image,
                     mounts: ["/h:/c"],
                     repos: [%{url: "https://example.invalid/r", dest: "/r"}],
                     copy: [%{src: "/tmp", dest: "/d"}],
                     env: ["LITERAL=value"]
                   )

          assert msg =~ "local image paths"
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "true is equivalent to default" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.prepare(@local_image,
                     disk_mount_enabled: true,
                     mounts: ["/h:/c"]
                   )
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "false strips :mounts and logs the stripped value" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.prepare(@local_image,
                     disk_mount_enabled: false,
                     mounts: ["/h:/c"]
                   )
        end)

      assert log =~ "disk_mount_enabled=false stripped :mounts"
      assert log =~ "/h:/c"
    end

    test "false strips :repos and :copy with one log per key" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.prepare(@local_image,
                     disk_mount_enabled: false,
                     repos: [%{url: "https://example.invalid/r", dest: "/r"}],
                     copy: [%{src: "/tmp", dest: "/d"}]
                   )
        end)

      assert log =~ "stripped :repos"
      assert log =~ "stripped :copy"
    end

    test "false strips bare-name and tuple :env entries but keeps literals" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.prepare(@local_image,
                     disk_mount_enabled: false,
                     env: ["FOO", "BAR=baz", {"QUX", default: "x"}]
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
                   Dockd.prepare(@local_image,
                     disk_mount_enabled: false,
                     env: ["LITERAL=value"]
                   )
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "false with empty host-exposing lists logs nothing" do
      log =
        capture_log(fn ->
          assert {:error, %Dockd.Error{phase: :validate}} =
                   Dockd.prepare(@local_image,
                     disk_mount_enabled: false,
                     mounts: [],
                     repos: [],
                     copy: []
                   )
        end)

      refute log =~ "disk_mount_enabled=false"
    end

    test "non-boolean :disk_mount_enabled is rejected at :validate" do
      assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
               Dockd.prepare(@local_image, disk_mount_enabled: "yes")

      assert msg =~ ":disk_mount_enabled must be a boolean"
    end

    test "option_keys/0 includes :disk_mount_enabled" do
      assert :disk_mount_enabled in Dockd.option_keys()
    end
  end

  describe "prepare/2 with :repos" do
    @tag :network
    test "clones a repo on the host and uploads it into the container" do
      assert {:ok, session} =
               Dockd.prepare(@image,
                 repos: [
                   %{
                     url: "https://github.com/octocat/Hello-World.git",
                     dest: "/workspace/hello"
                   }
                 ],
                 steps: [
                   %{label: "ls", cmd: ["ls", "/workspace/hello"]},
                   %{label: "no-git", cmd: ["sh", "-lc", "[ ! -d /workspace/hello/.git ]"]}
                 ]
               )

      on_exit(fn -> Dockd.destroy(session) end)

      assert Enum.map(session.step_results, & &1.exit_code) == [0, 0]
      assert hd(session.step_results).output =~ "README"
    end

    test "errors with :validate when :url is missing" do
      assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
               Dockd.prepare(@image, repos: [%{dest: "/workspace/x"}])

      assert msg =~ "must include a non-empty :url"
    end

    test "errors with :validate when :dest is not absolute" do
      assert {:error, %Dockd.Error{phase: :validate, message: msg}} =
               Dockd.prepare(@image,
                 repos: [%{url: "https://github.com/foo/bar", dest: "rel"}]
               )

      assert msg =~ "must be an absolute path"
    end
  end
end
