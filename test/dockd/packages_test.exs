defmodule Dockd.PackagesTest do
  use ExUnit.Case, async: false

  alias Dockd.Packages

  setup do
    previous_packages_path = Application.get_env(:dockd, :packages_path)
    previous_env = System.get_env("DOCKD_PACKAGES_PATH")

    on_exit(fn ->
      restore_app_env(previous_packages_path)
      restore_env(previous_env)
    end)

    :ok
  end

  describe "packages_root/1" do
    test "defaults to ~/.dockd/packages" do
      System.delete_env("DOCKD_PACKAGES_PATH")
      Application.delete_env(:dockd, :packages_path)

      assert Packages.packages_root() === Path.join(System.user_home!(), ".dockd/packages")
    end

    test "uses app config when set" do
      System.delete_env("DOCKD_PACKAGES_PATH")
      Application.put_env(:dockd, :packages_path, "/tmp/from-config")

      assert Packages.packages_root() === "/tmp/from-config"
    end

    test "uses environment before app config" do
      Application.put_env(:dockd, :packages_path, "/tmp/from-config")
      System.put_env("DOCKD_PACKAGES_PATH", "/tmp/from-env")

      assert Packages.packages_root() === "/tmp/from-env"
    end

    test "uses opts before environment and app config" do
      Application.put_env(:dockd, :packages_path, "/tmp/from-config")
      System.put_env("DOCKD_PACKAGES_PATH", "/tmp/from-env")

      assert Packages.packages_root(packages_path: "/tmp/from-opts") === "/tmp/from-opts"
    end
  end

  describe "resolve_path/1" do
    test "bare name resolves to <packages_root>/<name>/package.json" do
      root = sandbox_dir("dockd-packages-root")
      path = Packages.resolve_path("webapp", packages_path: root)

      assert Path.basename(path) === "package.json"
      assert Path.basename(Path.dirname(path)) === "webapp"

      assert path ===
               Path.join([root, "webapp", "package.json"])
    end

    test "directory path appends package.json" do
      assert Packages.resolve_path("./mypkg") === "./mypkg/package.json"
      assert Packages.resolve_path("/abs/mypkg") === "/abs/mypkg/package.json"
    end

    test "explicit .json path is used as-is" do
      assert Packages.resolve_path("./mypkg/package.json") === "./mypkg/package.json"
      assert Packages.resolve_path("/abs/path/spec.json") === "/abs/path/spec.json"
    end
  end

  describe "list/0" do
    test "lists every installed package with its parsed spec" do
      root = sandbox_dir("dockd-list-root")
      add_installed_package(root, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))

      results = Packages.list(packages_path: root)
      assert is_list(results)
      assert Enum.map(results, & &1.name) === ["alpha"]

      Enum.each(results, fn entry ->
        assert is_binary(entry.name)
        assert is_binary(entry.path)
        assert match?({:ok, %Dockd.Spec{}}, entry.spec) or match?({:error, _}, entry.spec)
      end)
    end

    test "returns {:ok, spec} for packages that reference unset env vars" do
      root = sandbox_dir("dockd-list-env-root")

      add_installed_package(
        root,
        "env",
        ~s({"instance_name": "env", "image": "busybox:1.37.0", "mounts": ["${DOCKD_TEST_UNSET}:/x"]})
      )

      results = Packages.list(packages_path: root)

      Enum.each(results, fn entry ->
        case entry.spec do
          {:ok, _} ->
            :ok

          {:error, err} ->
            refute err.message =~ "unset env var",
                   "Packages.list should not interpolate; got: #{inspect(err)}"
        end
      end)
    end
  end

  describe "install_from_git/2" do
    @describetag :integration

    setup do
      if System.find_executable("git") do
        :ok
      else
        {:skip, "git binary not available on PATH"}
      end
    end

    test "installs every package/<name>/ directory containing package.json" do
      repo = make_repo()
      dest = sandbox_dir("dockd-install-dest")

      add_package(repo, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))

      add_package(repo, "beta", ~s({"instance_name": "beta", "image": "busybox:1.37.0"}),
        dockerfile: "FROM busybox\n"
      )

      File.mkdir_p!(Path.join([repo, "packages", "no_json"]))
      File.write!(Path.join([repo, "packages", "no_json", "README"]), "skip me")
      git_commit(repo, "add packages")

      assert {:ok, names} =
               Packages.install_from_git("file://" <> repo, dest_dir: dest)

      assert Enum.sort(names) === ["alpha", "beta"]
      assert File.exists?(Path.join([dest, "alpha", "package.json"]))
      assert File.exists?(Path.join([dest, "beta", "package.json"]))
      assert File.exists?(Path.join([dest, "beta", "Dockerfile"]))
      refute File.exists?(Path.join(dest, "no_json"))
    end

    test "overwrites an existing package directory" do
      repo = make_repo()
      dest = sandbox_dir("dockd-install-overwrite")

      File.mkdir_p!(Path.join(dest, "alpha"))
      File.write!(Path.join([dest, "alpha", "stale.txt"]), "leftover")

      add_package(repo, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))
      git_commit(repo, "add alpha")

      assert {:ok, ["alpha"]} =
               Packages.install_from_git("file://" <> repo, dest_dir: dest)

      refute File.exists?(Path.join([dest, "alpha", "stale.txt"]))
      assert File.exists?(Path.join([dest, "alpha", "package.json"]))
    end

    test "errors when a package.json fails to parse" do
      repo = make_repo()
      dest = sandbox_dir("dockd-install-bad")

      add_package(repo, "broken", ~s({"shell": "/bin/sh"}))
      git_commit(repo, "add broken")

      assert {:error, err} =
               Packages.install_from_git("file://" <> repo, dest_dir: dest)

      assert err.phase === :fetch
      assert err.message =~ "broken"
    end

    test "errors when the repo has no packages/ directory" do
      repo = make_repo()
      dest = sandbox_dir("dockd-install-empty")

      File.write!(Path.join(repo, "README"), "no packages here")
      git_commit(repo, "init")

      assert {:error, err} =
               Packages.install_from_git("file://" <> repo, dest_dir: dest)

      assert err.phase === :fetch
      assert err.message =~ "no top-level packages/ directory"
    end

    test "errors when the URL is not cloneable" do
      dest = sandbox_dir("dockd-install-bogus")

      assert {:error, err} =
               Packages.install_from_git("file:///nonexistent/repo.git", dest_dir: dest)

      assert err.phase === :fetch
      assert err.message =~ "failed to clone"
    end
  end

  describe "install_from_path/2" do
    test "installs every packages/<name>/ dir from a local directory" do
      src = sandbox_dir("dockd-local-src")
      dest = sandbox_dir("dockd-local-dest")

      add_package(src, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))

      add_package(src, "beta", ~s({"instance_name": "beta", "image": "busybox:1.37.0"}),
        dockerfile: "FROM busybox\n"
      )

      assert {:ok, names} = Packages.install_from_path(src, dest_dir: dest)

      assert Enum.sort(names) === ["alpha", "beta"]
      assert File.exists?(Path.join([dest, "alpha", "package.json"]))
      assert File.exists?(Path.join([dest, "beta", "Dockerfile"]))
    end

    test "errors when the directory has no packages/ subdir" do
      src = sandbox_dir("dockd-local-empty")
      File.mkdir_p!(src)
      dest = sandbox_dir("dockd-local-empty-dest")

      assert {:error, err} = Packages.install_from_path(src, dest_dir: dest)
      assert err.phase === :fetch
      assert err.message =~ "no top-level packages/ directory"
    end
  end

  describe "Dockd.install_packages/2" do
    test "installs from a local directory when the ref is an existing dir" do
      src = sandbox_dir("dockd-dispatch-local")
      dest = sandbox_dir("dockd-dispatch-local-dest")

      add_package(src, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))

      assert {:ok, ["alpha"]} = Dockd.install_packages(src, dest_dir: dest)
      assert File.exists?(Path.join([dest, "alpha", "package.json"]))
    end

    @tag :integration
    test "treats a non-directory ref as a git URL" do
      if System.find_executable("git") do
        repo = make_repo()
        dest = sandbox_dir("dockd-dispatch-git-dest")

        add_package(repo, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))
        git_commit(repo, "add alpha")

        assert {:ok, ["alpha"]} =
                 Dockd.install_packages("file://" <> repo, dest_dir: dest)

        assert File.exists?(Path.join([dest, "alpha", "package.json"]))
      end
    end

    test "a non-directory ref that is not cloneable fails on the git path" do
      dest = sandbox_dir("dockd-dispatch-bogus")

      assert {:error, err} =
               Dockd.install_packages("file:///nonexistent/repo.git", dest_dir: dest)

      assert err.phase === :fetch
      assert err.message =~ "failed to clone"
    end
  end

  describe "Dockd.list_packages/1" do
    test "lists installed packages after an install" do
      src = sandbox_dir("dockd-list-src")
      root = sandbox_dir("dockd-list-root")

      add_package(src, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))
      assert {:ok, ["alpha"]} = Dockd.install_packages(src, dest_dir: root)

      assert [%{name: "alpha", path: path, spec: {:ok, spec}}] =
               Dockd.list_packages(packages_path: root)

      assert path === Path.join(root, "alpha")
      assert spec.image === "busybox:1.37.0"
    end

    test "returns [] when the packages root does not exist" do
      assert Dockd.list_packages(packages_path: sandbox_dir("dockd-list-missing")) === []
    end
  end

  describe "Dockd.new_package/2" do
    test "writes package.json and Dockerfile into the given directory" do
      dir = Path.join(sandbox_dir("dockd-new-pkg"), "greeter")

      assert {:ok, result} = Dockd.new_package(dir, from: "busybox:1.37.0")

      assert result.instance_name === "greeter"
      assert result.path === dir
      refute result.overwrote?

      assert result.files === [
               Path.join(dir, "package.json"),
               Path.join(dir, "Dockerfile")
             ]

      assert File.read!(Path.join(dir, "Dockerfile")) === "FROM busybox:1.37.0\n"
    end

    test "the generated package parses as a Spec" do
      dir = Path.join(sandbox_dir("dockd-new-parse"), "greeter")
      assert {:ok, _} = Dockd.new_package(dir, image: "dockd-greeter:1")

      root = Path.dirname(dir)

      assert [%{name: "greeter", spec: {:ok, spec}}] =
               Dockd.list_packages(packages_path: root)

      assert spec.image === "dockd-greeter:1"
      assert spec.instance_name === "dockd-greeter"
      assert spec.build === %{dockerfile: Path.join(dir, "Dockerfile")}
    end

    test "defaults the instance name to the directory basename" do
      dir = Path.join(sandbox_dir("dockd-new-basename"), "webapp")
      assert {:ok, %{instance_name: "webapp"}} = Dockd.new_package(dir)

      decoded = JSON.decode!(File.read!(Path.join(dir, "package.json")))
      assert decoded["instance_name"] === "webapp"
      assert decoded["image"] === "dockd-webapp:latest"
    end

    test "writes a package.json a human can edit" do
      dir = Path.join(sandbox_dir("dockd-new-pretty"), "greeter")
      assert {:ok, _} = Dockd.new_package(dir)

      body = File.read!(Path.join(dir, "package.json"))

      assert body =~ ~s(  "instance_name": "greeter")
      assert length(String.split(body, "\n")) > 3
    end

    test "refuses to overwrite an existing directory without :force" do
      dir = Path.join(sandbox_dir("dockd-new-collide"), "greeter")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "keep.txt"), "mine")

      assert {:error, err} = Dockd.new_package(dir)

      assert err.phase === :generate
      assert err.message =~ "already exists"
      assert File.read!(Path.join(dir, "keep.txt")) === "mine"
      refute File.exists?(Path.join(dir, "package.json"))
    end

    test "replaces an existing directory with force: true" do
      dir = Path.join(sandbox_dir("dockd-new-force"), "greeter")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "stale.txt"), "old")

      assert {:ok, %{overwrote?: true}} = Dockd.new_package(dir, force: true)

      refute File.exists?(Path.join(dir, "stale.txt"))
      assert File.exists?(Path.join(dir, "package.json"))
    end

    test "writes nothing when the options are invalid" do
      dir = Path.join(sandbox_dir("dockd-new-invalid"), "greeter")

      assert {:error, err} =
               Dockd.new_package(dir, env: [{"FOO", value: "a", optional: true}])

      assert err.phase === :validate
      refute File.exists?(dir)
    end

    test "writes nothing when the instance name is unusable" do
      dir = Path.join(sandbox_dir("dockd-new-badname"), "not a name")

      assert {:error, err} = Dockd.new_package(dir)

      assert err.phase === :validate
      refute File.exists?(dir)
    end
  end

  defp make_repo do
    dir = sandbox_dir("dockd-install-repo")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "--quiet", "-b", "main", dir], stderr_to_stdout: true)
    dir
  end

  defp add_package(repo, name, package_json, opts \\ []) do
    pkg_dir = Path.join([repo, "packages", name])
    File.mkdir_p!(pkg_dir)
    File.write!(Path.join(pkg_dir, "package.json"), package_json)

    case Keyword.get(opts, :dockerfile) do
      nil -> :ok
      contents -> File.write!(Path.join(pkg_dir, "Dockerfile"), contents)
    end
  end

  defp git_commit(repo, message) do
    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=dockd@example.test",
          "-c",
          "user.name=dockd test",
          "-c",
          "commit.gpgsign=false",
          "-C",
          repo,
          "add",
          "."
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=dockd@example.test",
          "-c",
          "user.name=dockd test",
          "-c",
          "commit.gpgsign=false",
          "-C",
          repo,
          "commit",
          "--quiet",
          "-m",
          message
        ],
        stderr_to_stdout: true
      )
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

  defp add_installed_package(root, name, package_json) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "package.json"), package_json)
  end

  defp restore_app_env(nil), do: Application.delete_env(:dockd, :packages_path)
  defp restore_app_env(value), do: Application.put_env(:dockd, :packages_path, value)

  defp restore_env(nil), do: System.delete_env("DOCKD_PACKAGES_PATH")
  defp restore_env(value), do: System.put_env("DOCKD_PACKAGES_PATH", value)
end
