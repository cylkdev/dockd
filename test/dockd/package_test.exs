defmodule Dockd.PackageTest do
  use ExUnit.Case, async: false

  alias Dockd.Error
  alias Dockd.Package

  @fixtures_dir Path.expand("../fixtures/packages", __DIR__)
  @claude_fixture Path.join(@fixtures_dir, "claude_code_with_api_key.json")

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "dockd-package-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  defp write_json(tmp_dir, contents) do
    path = Path.join(tmp_dir, "package.json")
    File.write!(path, contents)
    path
  end

  describe "load/1 with a minimal valid package" do
    test "returns image and empty opts", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "busybox:latest"}))

      assert {:ok, {"busybox:latest", []}} = Package.load(path)
    end

    test "preserves passthrough keys as a keyword list", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({
          "image": "busybox:latest",
          "shell": "/bin/sh",
          "env": [{"name": "FOO", "value": "bar"}],
          "mounts": ["/host:/container"]
        }))

      assert {:ok, {"busybox:latest", opts}} = Package.load(path)
      assert opts[:shell] == "/bin/sh"
      assert opts[:env] == [{"FOO", [value: "bar"]}]
      assert opts[:mounts] == ["/host:/container"]
    end

    test "passes steps through with string keys intact", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({
          "image": "busybox:latest",
          "steps": [
            {"label": "echo", "cmd": ["echo", "hi"]}
          ]
        }))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:steps] == [%{"label" => "echo", "cmd" => ["echo", "hi"]}]
    end
  end

  describe "load/1 with a bundled package name" do
    test "resolves a bare name to priv/packages/<name>.json" do
      System.put_env("PWD", "/tmp/proj")
      System.put_env("HOME", "/tmp/home")

      assert {:ok, {"dockd/claude-code:latest", opts}} =
               Package.load("claude_code_live_workspace")

      assert opts[:shell] == "claude"
      assert opts[:mounts] == ["/tmp/proj:/workspace", "/tmp/home/.claude:/root/.claude"]

      env = Keyword.fetch!(opts, :env)
      assert {"ANTHROPIC_API_KEY", [optional: true]} in env
      assert {"CLAUDE_CODE_OAUTH_TOKEN", [optional: true]} in env
      assert Enum.all?(env, fn {_name, opts} -> opts == [optional: true] end)

      build = Keyword.fetch!(opts, :build)
      assert Path.type(Map.fetch!(build, :dockerfile)) == :absolute
      assert Path.basename(Map.fetch!(build, :dockerfile)) == "claude_code.Dockerfile"
    end

    test "errors with a useful message for an unknown bundled name" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Package.load("definitely_not_a_real_package")

      assert msg =~ "could not read package"
      assert msg =~ "definitely_not_a_real_package.json"
    end

    test "treats strings ending in .json as paths, not bundled names", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img"}))

      assert {:ok, {"img", _}} = Package.load(path)
    end

    test "treats strings containing / as paths, not bundled names" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Package.load("./not/a/real/file")

      assert msg =~ "could not read package"
      assert msg =~ "./not/a/real/file"
    end
  end

  describe "load/1 with ${VAR:-default} interpolation" do
    test "uses the default when the env var is unset", %{tmp_dir: tmp_dir} do
      System.delete_env("DOCKD_NO_VAR")
      path = write_json(tmp_dir, ~s({"image": "img", "shell": "${DOCKD_NO_VAR:-zsh}"}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:shell] == "zsh"
    end

    test "prefers the env var when set", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_VAR", "real")
      on_exit(fn -> System.delete_env("DOCKD_VAR") end)
      path = write_json(tmp_dir, ~s({"image": "img", "shell": "${DOCKD_VAR:-fallback}"}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:shell] == "real"
    end

    test "supports an explicit empty default", %{tmp_dir: tmp_dir} do
      System.delete_env("DOCKD_NO_VAR")
      path = write_json(tmp_dir, ~s({"image": "img", "shell": "prefix-${DOCKD_NO_VAR:-}"}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:shell] == "prefix-"
    end
  end

  describe "load/1 with :mounts (string and structured shapes)" do
    test "passes structured-map mount entries through", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({
          "image": "img",
          "mounts": [
            {"type": "tmpfs", "target": "/scratch"},
            "/host:/container:ro"
          ]
        }))

      assert {:ok, {_, opts}} = Package.load(path)

      assert opts[:mounts] == [
               %{"type" => "tmpfs", "target" => "/scratch"},
               "/host:/container:ro"
             ]
    end

    test "rejects :binds at the unknown-key check", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "binds": ["/h:/c"]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "unknown package key"
      assert msg =~ "binds"
    end
  end

  describe "load/1 with :env (object-form entries)" do
    test "normalizes a bare-name passthrough entry to a tuple", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "env": [{"name": "FOO"}]}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:env] == [{"FOO", []}]
    end

    test "normalizes a literal value entry to a value-tuple", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({"image": "img", "env": [{"name": "FOO", "value": "bar"}]}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:env] == [{"FOO", [value: "bar"]}]
    end

    test "normalizes a default entry to a default-tuple", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({"image": "img", "env": [{"name": "FOO", "default": "x"}]}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:env] == [{"FOO", [default: "x"]}]
    end

    test "normalizes an optional entry to an optional-tuple", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({"image": "img", "env": [{"name": "FOO", "optional": true}]}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:env] == [{"FOO", [optional: true]}]
    end

    test "rejects string entries in JSON env", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "env": ["FOO"]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ":env entries must be JSON objects"
    end

    test "rejects literal=value strings in JSON env", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "env": ["FOO=bar"]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ":env entries must be JSON objects"
    end

    test "rejects number entries in JSON env", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "env": [42]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ":env entries must be JSON objects"
    end

    test "rejects list entries in JSON env", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "env": [["FOO"]]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ":env entries must be JSON objects"
    end

    test "rejects entry missing name", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "env": [{"value": "bar"}]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ~s(non-empty string "name")
    end

    test "rejects empty-string name", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "env": [{"name": ""}]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ~s(non-empty string "name")
    end

    test "rejects unknown key in entry", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({"image": "img", "env": [{"name": "FOO", "wat": 1}]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "unknown key"
      assert msg =~ "wat"
    end

    test "rejects non-string value", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({"image": "img", "env": [{"name": "FOO", "value": 1}]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ~s("value" must be a string)
      assert msg =~ "FOO"
    end

    test "rejects non-string default", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({"image": "img", "env": [{"name": "FOO", "default": 1}]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ~s("default" must be a string)
    end

    test "rejects non-boolean optional", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({"image": "img", "env": [{"name": "FOO", "optional": "yes"}]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ~s("optional" must be a boolean)
    end

    test "rejects value + default together", %{tmp_dir: tmp_dir} do
      path =
        write_json(
          tmp_dir,
          ~s({"image": "img", "env": [{"name": "FOO", "value": "a", "default": "b"}]})
        )

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ~s("value" cannot coexist with "default")
    end

    test "rejects value + optional together", %{tmp_dir: tmp_dir} do
      path =
        write_json(
          tmp_dir,
          ~s({"image": "img", "env": [{"name": "FOO", "value": "a", "optional": true}]})
        )

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ~s("value" cannot coexist with "optional")
    end

    test "rejects default + optional together", %{tmp_dir: tmp_dir} do
      path =
        write_json(
          tmp_dir,
          ~s({"image": "img", "env": [{"name": "FOO", "default": "a", "optional": true}]})
        )

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ~s("default" cannot coexist with "optional")
    end

    test "rejects non-list :env", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "env": {"name": "FOO"}}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ ~s(package key "env" must be a list)
    end

    test "rejects :inherit_env at the unknown-key check", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "inherit_env": ["FOO"]}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "unknown package key"
      assert msg =~ "inherit_env"
    end
  end

  describe "load/1 with :disk_mount_enabled" do
    test "passes a true value through to opts", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "disk_mount_enabled": true}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:disk_mount_enabled] == true
    end

    test "passes a false value through to opts", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "disk_mount_enabled": false}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:disk_mount_enabled] == false
    end
  end

  describe "load/1 with the claude_code_with_api_key fixture" do
    test "produces opts that round-trip to Dockd.prepare/2 shape" do
      System.put_env("ANTHROPIC_API_KEY", "sk-test-123")
      System.put_env("PWD", "/tmp/proj")

      on_exit(fn ->
        System.delete_env("ANTHROPIC_API_KEY")
      end)

      assert {:ok, {"node:20-slim", opts}} = Package.load(@claude_fixture)

      assert opts[:shell] == "claude"
      assert opts[:env] == [{"ANTHROPIC_API_KEY", []}]
      assert opts[:mounts] == ["/tmp/proj:/workspace"]

      assert opts[:steps] == [
               %{
                 "label" => "install claude-code",
                 "cmd" => ["npm", "install", "-g", "@anthropic-ai/claude-code"]
               }
             ]
    end
  end

  describe "load/1 with ${VAR} interpolation" do
    test "substitutes a present env var", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_TEST_VAR", "hello")
      on_exit(fn -> System.delete_env("DOCKD_TEST_VAR") end)

      path = write_json(tmp_dir, ~s({"image": "img", "shell": "${DOCKD_TEST_VAR}-shell"}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:shell] == "hello-shell"
    end

    test "substitutes inside lists and nested maps", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_TEST_VAR", "hi")
      on_exit(fn -> System.delete_env("DOCKD_TEST_VAR") end)

      path =
        write_json(tmp_dir, ~s({
          "image": "img",
          "env": [
            {"name": "A", "value": "${DOCKD_TEST_VAR}"},
            {"name": "B", "value": "plain"}
          ],
          "steps": [
            {"label": "${DOCKD_TEST_VAR}", "cmd": ["echo", "${DOCKD_TEST_VAR}"]}
          ]
        }))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:env] == [{"A", [value: "hi"]}, {"B", [value: "plain"]}]
      assert opts[:steps] == [%{"label" => "hi", "cmd" => ["echo", "hi"]}]
    end

    test "replaces multiple occurrences in one string", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_TEST_VAR", "x")
      on_exit(fn -> System.delete_env("DOCKD_TEST_VAR") end)

      path =
        write_json(tmp_dir, ~s({"image": "img", "shell": "${DOCKD_TEST_VAR}-${DOCKD_TEST_VAR}"}))

      assert {:ok, {_, opts}} = Package.load(path)
      assert opts[:shell] == "x-x"
    end

    test "errors on missing env var with var name and JSON path", %{tmp_dir: tmp_dir} do
      System.delete_env("DOCKD_TEST_MISSING")

      path =
        write_json(
          tmp_dir,
          ~s({"image": "img", "env": [{"name": "KEY", "value": "${DOCKD_TEST_MISSING}"}]})
        )

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "DOCKD_TEST_MISSING"
      assert msg =~ "$.env[0]"
    end
  end

  describe "load/1 with repos and copy" do
    test "passes repos through with string-keyed entries", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({
          "image": "img",
          "repos": [
            {"url": "https://github.com/foo/bar", "ref": "main", "dest": "/workspace/bar"}
          ]
        }))

      assert {:ok, {_, opts}} = Package.load(path)

      assert opts[:repos] == [
               %{
                 "url" => "https://github.com/foo/bar",
                 "ref" => "main",
                 "dest" => "/workspace/bar"
               }
             ]
    end

    test "passes copy through with string-keyed entries and interpolation", %{tmp_dir: tmp_dir} do
      System.put_env("DOCKD_TEST_PWD", "/tmp/proj")
      on_exit(fn -> System.delete_env("DOCKD_TEST_PWD") end)

      path =
        write_json(tmp_dir, ~s({
          "image": "img",
          "copy": [
            {"src": "${DOCKD_TEST_PWD}/config.yaml", "dest": "/etc/app/config.yaml", "mode": "0600"}
          ]
        }))

      assert {:ok, {_, opts}} = Package.load(path)

      assert opts[:copy] == [
               %{
                 "src" => "/tmp/proj/config.yaml",
                 "dest" => "/etc/app/config.yaml",
                 "mode" => "0600"
               }
             ]
    end
  end

  describe "load/1 validation errors" do
    test "rejects unknown top-level key", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "wat": true}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "unknown package key"
      assert msg =~ "wat"
    end

    test "rejects non-object top-level JSON", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, "[]")

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "must be a JSON object"
    end

    test "rejects missing image", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"shell": "/bin/sh"}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "missing required key"
      assert msg =~ "image"
    end

    test "rejects non-string image", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": 42}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "must be a string"
    end

    test "rejects invalid JSON", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, "{not json")

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "invalid JSON"
    end

    test "rejects nonexistent file" do
      assert {:error, %Error{phase: :validate, message: msg}} =
               Package.load("/nonexistent/package.json")

      assert msg =~ "could not read package"
    end

    test "rejects unknown :build key", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({"image": "img", "build": {"dockerfile": "x", "bogus": true}}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "unknown build key"
      assert msg =~ "bogus"
    end

    test "rejects non-object :build", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "build": "nope"}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "build"
      assert msg =~ "must be an object"
    end

    test "atom-ifies valid :build keys (Compose-style)", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, ~s({
          "image": "img",
          "build": {"dockerfile": "./Dockerfile", "nocache": true, "args": {"FOO": "bar"}}
        }))

      assert {:ok, {_, opts}} = Package.load(path)

      # Relative dockerfile paths are expanded against the package file's directory
      # so a bundled or shared package travels with its Dockerfile.
      assert opts[:build] == %{
               dockerfile: Path.join(tmp_dir, "Dockerfile"),
               nocache: true,
               args: %{"FOO" => "bar"}
             }
    end

    test "rejects :build_params (renamed) at the unknown-key check", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "build_params": {"nocache": true}}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "unknown package key"
      assert msg =~ "build_params"
    end

    test "rejects top-level :dockerfile (now nested under :build)", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, ~s({"image": "img", "dockerfile": "./Dockerfile"}))

      assert {:error, %Error{phase: :validate, message: msg}} = Package.load(path)
      assert msg =~ "unknown package key"
      assert msg =~ "dockerfile"
    end
  end
end
