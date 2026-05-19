defmodule Dockd.Ssh.DockerDialStdioTest do
  use ExUnit.Case, async: true

  alias Dockd.Ssh.DockerDialStdio

  describe "template_path/0" do
    test "returns a path that exists on disk and ends in .sh.eex" do
      path = DockerDialStdio.template_path()
      assert is_binary(path) or is_list(path)
      assert File.exists?(path), "expected #{inspect(path)} to exist on disk"
      assert String.ends_with?(to_string(path), "docker_dial_stdio_script.sh.eex")
    end
  end

  describe "local_path/0" do
    test "is a back-compat alias for template_path/0" do
      assert DockerDialStdio.local_path() === DockerDialStdio.template_path()
    end
  end

  describe "render_script/1" do
    test "returns a binary that starts with #!/bin/sh" do
      script = DockerDialStdio.render_script()
      assert is_binary(script)

      assert String.starts_with?(script, "#!/bin/sh"),
             "expected rendered script to start with #!/bin/sh; got: #{String.slice(script, 0, 40)}"
    end

    test "accepts an assigns keyword and ignores unused keys" do
      assert DockerDialStdio.render_script(unused: "value") ===
               DockerDialStdio.render_script()
    end
  end

  describe "default_remote_path/0" do
    test "returns the documented constant" do
      assert DockerDialStdio.default_remote_path() ===
               "/usr/local/bin/docker-stdio-bridge"
    end
  end

  describe "build_plan/5 - default remote path" do
    test "uses default remote path when no override is given" do
      default = DockerDialStdio.default_remote_path()
      local = DockerDialStdio.template_path()

      plan = DockerDialStdio.build_plan(local, "user@host", default, nil, nil)

      assert [
               {:scp, "scp", scp_args, :no_check},
               {:ssh_chmod, "ssh", ssh_chmod_args, :no_check},
               {:ssh_verify, "ssh", ssh_verify_args, :expect_ok}
             ] = plan

      assert List.last(scp_args) === "user@host:#{default}"
      assert ssh_chmod_args === ["user@host", "chmod", "+x", default]
      assert ssh_verify_args === ["user@host", "[ -x #{default} ] && echo ok"]
    end
  end

  describe "build_plan/5 - --remote-path override" do
    test "propagates the override into every step's argv" do
      local = DockerDialStdio.template_path()

      plan = DockerDialStdio.build_plan(local, "user@host", "/opt/bin/bridge", nil, nil)

      assert [
               {:scp, "scp", scp_args, :no_check},
               {:ssh_chmod, "ssh", ssh_chmod_args, :no_check},
               {:ssh_verify, "ssh", ssh_verify_args, :expect_ok}
             ] = plan

      assert List.last(scp_args) === "user@host:/opt/bin/bridge"
      assert ssh_chmod_args === ["user@host", "chmod", "+x", "/opt/bin/bridge"]
      assert ssh_verify_args === ["user@host", "[ -x /opt/bin/bridge ] && echo ok"]
    end
  end

  describe "build_plan/5 - argv shapes" do
    test "exact scp/ssh argv with identity and port flags" do
      default = DockerDialStdio.default_remote_path()
      local = DockerDialStdio.template_path()

      plan =
        DockerDialStdio.build_plan(
          local,
          "deploy@example.com",
          default,
          "/home/me/.ssh/id_ed25519",
          "2222"
        )

      assert [
               {:scp, "scp", scp_args, :no_check},
               {:ssh_chmod, "ssh", ssh_chmod_args, :no_check},
               {:ssh_verify, "ssh", ssh_verify_args, :expect_ok}
             ] = plan

      assert scp_args === [
               "-i",
               "/home/me/.ssh/id_ed25519",
               "-P",
               "2222",
               local,
               "deploy@example.com:#{default}"
             ]

      assert ssh_chmod_args === [
               "-i",
               "/home/me/.ssh/id_ed25519",
               "-p",
               "2222",
               "deploy@example.com",
               "chmod",
               "+x",
               default
             ]

      assert ssh_verify_args === [
               "-i",
               "/home/me/.ssh/id_ed25519",
               "-p",
               "2222",
               "deploy@example.com",
               "[ -x #{default} ] && echo ok"
             ]
    end

    test "no identity or port flags when not provided" do
      default = DockerDialStdio.default_remote_path()
      local = DockerDialStdio.template_path()

      plan = DockerDialStdio.build_plan(local, "user@host", default, nil, nil)

      assert [
               {:scp, "scp", scp_args, :no_check},
               {:ssh_chmod, "ssh", ssh_chmod_args, :no_check},
               _
             ] = plan

      assert scp_args === [local, "user@host:#{default}"]
      assert ssh_chmod_args === ["user@host", "chmod", "+x", default]
    end
  end

  describe "build_content_plan/4" do
    test "produces a single ssh step that cats stdin to the remote path, chmods, and verifies" do
      default = DockerDialStdio.default_remote_path()

      plan = DockerDialStdio.build_content_plan("user@host", default, nil, nil)

      assert [{:ssh_pipe, "ssh", argv, :expect_ok}] = plan

      assert argv === [
               "user@host",
               "cat > #{default} && chmod +x #{default} && [ -x #{default} ] && echo ok"
             ]
    end

    test "propagates identity and port flags" do
      plan =
        DockerDialStdio.build_content_plan(
          "deploy@example.com",
          "/opt/bin/bridge",
          "/home/me/.ssh/id_ed25519",
          "2222"
        )

      assert [{:ssh_pipe, "ssh", argv, :expect_ok}] = plan

      assert argv === [
               "-i",
               "/home/me/.ssh/id_ed25519",
               "-p",
               "2222",
               "deploy@example.com",
               "cat > /opt/bin/bridge && chmod +x /opt/bin/bridge && [ -x /opt/bin/bridge ] && echo ok"
             ]
    end

    test "honors a custom remote path" do
      plan = DockerDialStdio.build_content_plan("user@host", "/opt/bin/bridge", nil, nil)

      assert [{:ssh_pipe, "ssh", argv, :expect_ok}] = plan
      remote_cmd = List.last(argv)
      assert String.contains?(remote_cmd, "cat > /opt/bin/bridge")
      assert String.contains?(remote_cmd, "chmod +x /opt/bin/bridge")
      assert String.contains?(remote_cmd, "[ -x /opt/bin/bridge ]")
    end
  end
end
