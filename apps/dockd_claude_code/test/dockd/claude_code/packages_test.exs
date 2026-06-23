defmodule Dockd.ClaudeCode.PackagesTest do
  use ExUnit.Case, async: false

  alias Dockd.ClaudeCode.Packages

  setup do
    previous_env = System.get_env("DOCKD_PACKAGES_PATH")
    previous_config = Application.get_env(:dockd_claude_code, :packages_path)

    on_exit(fn ->
      restore_env(previous_env)
      restore_config(previous_config)
    end)

    System.delete_env("DOCKD_PACKAGES_PATH")
    Application.delete_env(:dockd_claude_code, :packages_path)

    :ok
  end

  describe "packages_root/1" do
    test "defaults to the user package root" do
      assert Packages.packages_root() === Path.join(System.user_home!(), ".dockd/packages")
    end

    test "uses app config when env and opts are unset" do
      Application.put_env(:dockd_claude_code, :packages_path, "/tmp/from-config")

      assert Packages.packages_root() === "/tmp/from-config"
    end

    test "uses DOCKD_PACKAGES_PATH before app config" do
      Application.put_env(:dockd_claude_code, :packages_path, "/tmp/from-config")
      System.put_env("DOCKD_PACKAGES_PATH", "/tmp/from-env")

      assert Packages.packages_root() === "/tmp/from-env"
    end

    test "uses opts before env and app config" do
      Application.put_env(:dockd_claude_code, :packages_path, "/tmp/from-config")
      System.put_env("DOCKD_PACKAGES_PATH", "/tmp/from-env")

      assert Packages.packages_root(packages_path: "/tmp/from-opts") === "/tmp/from-opts"
    end
  end

  describe "generate/1" do
    test "writes every Claude Code package into the requested packages path" do
      root = sandbox_dir("dockd-claude-code-packages")

      assert {:ok, generated} = Packages.generate(packages_path: root)

      assert Enum.map(generated, & &1.name) === Packages.package_names()

      Enum.each(generated, fn %{name: name, path: path, files: files} ->
        assert path === Path.join(root, name)
        assert Enum.sort(Enum.map(files, &Path.basename/1)) === ["Dockerfile", "package.json"]

        assert File.read!(Path.join(path, "Dockerfile")) =~ "@anthropic-ai/claude-code"

        package = JSON.decode!(File.read!(Path.join(path, "package.json")))
        assert package["name"] === name
        assert package["image"] === "dockd/claude-code:latest"
        assert package["shell"] === "claude"
        assert package["build"] === %{"dockerfile" => "Dockerfile"}
      end)
    end

    test "does not overwrite existing package directories without force" do
      root = sandbox_dir("dockd-claude-code-no-force")
      existing = Path.join(root, "claude_code")
      File.mkdir_p!(existing)
      File.write!(Path.join(existing, "package.json"), "{}")

      assert {:error, message} = Packages.generate(packages_path: root)

      assert message =~ "already exists"
      assert File.read!(Path.join(existing, "package.json")) === "{}"
    end

    test "replaces existing package directories with force" do
      root = sandbox_dir("dockd-claude-code-force")
      existing = Path.join(root, "claude_code")
      File.mkdir_p!(existing)
      File.write!(Path.join(existing, "stale.txt"), "stale")

      assert {:ok, _generated} = Packages.generate(packages_path: root, force: true)

      refute File.exists?(Path.join(existing, "stale.txt"))
      assert File.exists?(Path.join(existing, "package.json"))
    end
  end

  defp sandbox_dir(prefix) do
    dir =
      Path.join([
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp restore_env(nil), do: System.delete_env("DOCKD_PACKAGES_PATH")
  defp restore_env(value), do: System.put_env("DOCKD_PACKAGES_PATH", value)

  defp restore_config(nil), do: Application.delete_env(:dockd_claude_code, :packages_path)
  defp restore_config(value), do: Application.put_env(:dockd_claude_code, :packages_path, value)
end
