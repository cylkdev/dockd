defmodule Dockd.Ssh.DockerDialStdioTest do
  use ExUnit.Case, async: true

  alias Dockd.Ssh.DockerDialStdio

  @ssh "/usr/bin/ssh"
  @scp "/usr/bin/scp"
  # The default the install functions apply when :ssh_opts is omitted.
  @batch ["-o", "BatchMode=yes"]

  describe "default_template_path/0" do
    test "returns a path that exists on disk and ends in .sh.eex" do
      path = DockerDialStdio.default_template_path()
      assert is_binary(path) or is_list(path)
      assert File.exists?(path), "expected #{inspect(path)} to exist on disk"
      assert String.ends_with?(to_string(path), "docker_dial_stdio_script.sh.eex")
    end
  end

  describe "render_script/2" do
    test "returns a binary that starts with #!/bin/sh" do
      script = DockerDialStdio.render_script(DockerDialStdio.default_template_path())
      assert is_binary(script)

      assert String.starts_with?(script, "#!/bin/sh"),
             "expected rendered script to start with #!/bin/sh; got: #{String.slice(script, 0, 40)}"
    end

    test "accepts an assigns keyword and ignores unused keys" do
      template = DockerDialStdio.default_template_path()

      assert DockerDialStdio.render_script(template, unused: "value") ===
               DockerDialStdio.render_script(template)
    end

    # The template path is an argument, so a caller can render their own.
    test "renders whichever template it is given" do
      path = Path.join(System.tmp_dir!(), "dockd-tpl-#{System.unique_integer([:positive])}.eex")
      File.write!(path, "hello <%= @who %>")
      on_exit(fn -> File.rm_rf!(path) end)

      assert DockerDialStdio.render_script(path, who: "world") === "hello world"
    end
  end

  describe "default_remote_path/0" do
    test "returns the documented constant" do
      assert DockerDialStdio.default_remote_path() ===
               "/usr/local/bin/docker-stdio-bridge"
    end
  end

  describe "build_plan/8" do
    test "uses the remote path it is given in every step" do
      default = DockerDialStdio.default_remote_path()
      local = DockerDialStdio.default_template_path()

      plan = DockerDialStdio.build_plan(local, "user@host", default, nil, nil, @ssh, @scp, [])

      assert [
               {:scp, @scp, scp_args, :no_check},
               {:ssh_chmod, @ssh, ssh_chmod_args, :no_check},
               {:ssh_verify, @ssh, ssh_verify_args, :expect_ok}
             ] = plan

      assert List.last(scp_args) === "user@host:#{default}"
      assert ssh_chmod_args === ["user@host", "chmod", "+x", default]
      assert ssh_verify_args === ["user@host", "[ -x #{default} ] && echo ok"]
    end

    test "propagates a remote-path override into every step's argv" do
      local = DockerDialStdio.default_template_path()

      plan =
        DockerDialStdio.build_plan(
          local,
          "user@host",
          "/opt/bin/bridge",
          nil,
          nil,
          @ssh,
          @scp,
          []
        )

      assert [
               {:scp, @scp, scp_args, :no_check},
               {:ssh_chmod, @ssh, ssh_chmod_args, :no_check},
               {:ssh_verify, @ssh, ssh_verify_args, :expect_ok}
             ] = plan

      assert List.last(scp_args) === "user@host:/opt/bin/bridge"
      assert ssh_chmod_args === ["user@host", "chmod", "+x", "/opt/bin/bridge"]
      assert ssh_verify_args === ["user@host", "[ -x /opt/bin/bridge ] && echo ok"]
    end

    test "exact scp/ssh argv with identity, port, and ssh_opts flags" do
      default = DockerDialStdio.default_remote_path()
      local = DockerDialStdio.default_template_path()

      plan =
        DockerDialStdio.build_plan(
          local,
          "deploy@example.com",
          default,
          "/home/me/.ssh/id_ed25519",
          "2222",
          @ssh,
          @scp,
          @batch
        )

      assert [
               {:scp, @scp, scp_args, :no_check},
               {:ssh_chmod, @ssh, ssh_chmod_args, :no_check},
               {:ssh_verify, @ssh, ssh_verify_args, :expect_ok}
             ] = plan

      base = ["-i", "/home/me/.ssh/id_ed25519", "-o", "BatchMode=yes"]

      assert scp_args ===
               base ++ ["-P", "2222", local, "deploy@example.com:#{default}"]

      assert ssh_chmod_args ===
               base ++ ["-p", "2222", "deploy@example.com", "chmod", "+x", default]

      assert ssh_verify_args ===
               base ++ ["-p", "2222", "deploy@example.com", "[ -x #{default} ] && echo ok"]
    end

    test "no identity, port, or ssh_opts flags when not provided" do
      default = DockerDialStdio.default_remote_path()
      local = DockerDialStdio.default_template_path()

      plan = DockerDialStdio.build_plan(local, "user@host", default, nil, nil, @ssh, @scp, [])

      assert [
               {:scp, @scp, scp_args, :no_check},
               {:ssh_chmod, @ssh, ssh_chmod_args, :no_check},
               _
             ] = plan

      assert scp_args === [local, "user@host:#{default}"]
      assert ssh_chmod_args === ["user@host", "chmod", "+x", default]
    end

    test "uses the ssh and scp executables it is given rather than bare names" do
      local = DockerDialStdio.default_template_path()

      plan =
        DockerDialStdio.build_plan(
          local,
          "user@host",
          "/opt/bin/bridge",
          nil,
          nil,
          "/opt/ssh",
          "/opt/scp",
          []
        )

      assert [{:scp, "/opt/scp", _, _}, {:ssh_chmod, "/opt/ssh", _, _}, {_, "/opt/ssh", _, _}] =
               plan
    end
  end

  describe "build_content_plan/6" do
    test "produces a single ssh step that cats stdin to the remote path, chmods, and verifies" do
      default = DockerDialStdio.default_remote_path()

      plan = DockerDialStdio.build_content_plan("user@host", default, nil, nil, @ssh, [])

      assert [{:ssh_pipe, @ssh, argv, :expect_ok}] = plan

      assert argv === [
               "user@host",
               "cat > '#{default}' && chmod +x '#{default}' && [ -x '#{default}' ] && echo ok"
             ]
    end

    test "propagates identity, port, and ssh_opts flags" do
      plan =
        DockerDialStdio.build_content_plan(
          "deploy@example.com",
          "/opt/bin/bridge",
          "/home/me/.ssh/id_ed25519",
          "2222",
          @ssh,
          @batch
        )

      assert [{:ssh_pipe, @ssh, argv, :expect_ok}] = plan

      assert argv === [
               "-i",
               "/home/me/.ssh/id_ed25519",
               "-o",
               "BatchMode=yes",
               "-p",
               "2222",
               "deploy@example.com",
               "cat > '/opt/bin/bridge' && chmod +x '/opt/bin/bridge' && " <>
                 "[ -x '/opt/bin/bridge' ] && echo ok"
             ]
    end

    # The path lands inside a remote shell command, so it is quoted rather than
    # interpolated bare.
    test "quotes the remote path in the remote shell command" do
      plan = DockerDialStdio.build_content_plan("user@host", "/opt/bin/bridge", nil, nil, @ssh, [])

      assert [{:ssh_pipe, @ssh, argv, :expect_ok}] = plan
      remote_cmd = List.last(argv)
      assert String.contains?(remote_cmd, "cat > '/opt/bin/bridge'")
      assert String.contains?(remote_cmd, "chmod +x '/opt/bin/bridge'")
      assert String.contains?(remote_cmd, "[ -x '/opt/bin/bridge' ]")
    end
  end

  describe "install/5 input validation" do
    test "requires ssh_path" do
      assert {:error, message} = DockerDialStdio.install(:default, "user@host", nil, @scp)
      assert message =~ "needs ssh"
    end

    test "requires scp_path for the file-based flow" do
      local = DockerDialStdio.default_template_path()

      assert {:error, message} = DockerDialStdio.install(local, "user@host", @ssh, nil)
      assert message =~ "needs scp"
    end

    test "rejects an ssh_path that does not name a file" do
      assert {:error, message} =
               DockerDialStdio.install(:default, "user@host", "/no/such/ssh", @scp)

      assert message =~ "ssh_path does not name a file"
    end

    # A remote_path with a space, `;`, or `$` would be expanded by the remote
    # shell, so it is refused before any connection is attempted.
    test "rejects a remote_path that the remote shell would expand" do
      ssh = executable!()

      for bad <- ["/opt/a b", "/opt/x;rm -rf /", "/opt/$(whoami)", "/opt/*"] do
        assert {:error, message} =
                 DockerDialStdio.install(:default, "user@host", ssh, ssh, remote_path: bad)

        assert message =~ "remote_path must contain only"
      end
    end

    test "rejects a relative remote_path" do
      ssh = executable!()

      assert {:error, message} =
               DockerDialStdio.install(:default, "user@host", ssh, ssh, remote_path: "bin/bridge")

      assert message =~ "remote_path must be an absolute path"
    end
  end

  defp executable! do
    path = Path.join(System.tmp_dir!(), "dockd-fake-ssh-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
