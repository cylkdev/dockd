defmodule Dockd.PackagesTest do
  use ExUnit.Case, async: false

  alias Dockd.Packages

  describe "resolve_path/3" do
    test "bare name resolves to <root>/<name>/package.json" do
      root = sandbox_dir("dockd-packages-root")
      path = Packages.resolve_path(root, "webapp")

      assert Path.basename(path) === "package.json"
      assert Path.basename(Path.dirname(path)) === "webapp"

      assert path ===
               Path.join([root, "webapp", "package.json"])
    end

    test "directory path appends package.json" do
      assert Packages.resolve_path("/root", "./mypkg") === "./mypkg/package.json"
      assert Packages.resolve_path("/root", "/abs/mypkg") === "/abs/mypkg/package.json"
    end

    test "explicit .json path is used as-is" do
      assert Packages.resolve_path("/root", "./mypkg/package.json") === "./mypkg/package.json"
      assert Packages.resolve_path("/root", "/abs/path/spec.json") === "/abs/path/spec.json"
    end
  end

  describe "list/2" do
    test "lists every installed package with its parsed spec" do
      root = sandbox_dir("dockd-list-root")
      add_installed_package(root, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))

      results = Packages.list(root)
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

      results = Packages.list(root)

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

  describe "delete/3" do
    test "removes an installed package directory" do
      root = sandbox_dir("dockd-delete-root")
      add_installed_package(root, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))

      assert :ok = Packages.delete(root, "alpha")
      refute File.exists?(Path.join(root, "alpha"))
    end

    test "is idempotent — deleting a missing package returns :ok" do
      root = sandbox_dir("dockd-delete-missing")

      assert :ok = Packages.delete(root, "nope")
      assert :ok = Packages.delete(root, "nope")
    end

    test "only removes the named package" do
      root = sandbox_dir("dockd-delete-others")
      add_installed_package(root, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))
      add_installed_package(root, "beta", ~s({"instance_name": "beta", "image": "busybox:1.37.0"}))

      assert :ok = Packages.delete(root, "alpha")
      assert File.exists?(Path.join([root, "beta", "package.json"]))
    end

    test "rejects a reference that is not a bare package name" do
      root = sandbox_dir("dockd-delete-bare")

      for bad <- ["../etc", "a/b", "pkg.json", ""] do
        assert {:error, %Dockd.Error{phase: :validate}} = Packages.delete(root, bad)
      end
    end

    test "refuses to delete a directory that is not a package" do
      root = sandbox_dir("dockd-delete-notpkg")
      File.mkdir_p!(Path.join(root, "plain"))

      assert {:error, %Dockd.Error{phase: :destroy}} =
               Packages.delete(root, "plain")

      assert File.exists?(Path.join(root, "plain"))
    end
  end

  describe "Dockd.delete_package/3" do
    test "removes an installed package by name" do
      root = sandbox_dir("dockd-api-delete-root")
      add_installed_package(root, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))

      assert :ok = Dockd.delete_package(root, "alpha")
      assert Dockd.list_packages(root) === []
    end
  end

  describe "install_from_git/6" do
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
               Packages.install_from_git(dest, "file://" <> repo, staging(), git_path(), git_env())

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
               Packages.install_from_git(dest, "file://" <> repo, staging(), git_path(), git_env())

      refute File.exists?(Path.join([dest, "alpha", "stale.txt"]))
      assert File.exists?(Path.join([dest, "alpha", "package.json"]))
    end

    test "errors when a package.json fails to parse" do
      repo = make_repo()
      dest = sandbox_dir("dockd-install-bad")

      add_package(repo, "broken", ~s({"shell": "/bin/sh"}))
      git_commit(repo, "add broken")

      assert {:error, err} =
               Packages.install_from_git(dest, "file://" <> repo, staging(), git_path(), git_env())

      assert err.phase === :fetch
      assert err.message =~ "broken"
    end

    test "errors when the repo has no packages/ directory" do
      repo = make_repo()
      dest = sandbox_dir("dockd-install-empty")

      File.write!(Path.join(repo, "README"), "no packages here")
      git_commit(repo, "init")

      assert {:error, err} =
               Packages.install_from_git(dest, "file://" <> repo, staging(), git_path(), git_env())

      assert err.phase === :fetch
      assert err.message =~ "no top-level packages/ directory"
    end

    test "errors when the URL is not cloneable" do
      dest = sandbox_dir("dockd-install-bogus")

      assert {:error, err} =
               Packages.install_from_git(dest, "file:///nonexistent/repo.git", staging(), git_path(), git_env())

      assert err.phase === :fetch
      assert err.message =~ "failed to clone"
    end
  end

  describe "install_from_path/3" do
    test "installs every packages/<name>/ dir from a local directory" do
      src = sandbox_dir("dockd-local-src")
      dest = sandbox_dir("dockd-local-dest")

      add_package(src, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))

      add_package(src, "beta", ~s({"instance_name": "beta", "image": "busybox:1.37.0"}),
        dockerfile: "FROM busybox\n"
      )

      assert {:ok, names} = Packages.install_from_path(dest, src)

      assert Enum.sort(names) === ["alpha", "beta"]
      assert File.exists?(Path.join([dest, "alpha", "package.json"]))
      assert File.exists?(Path.join([dest, "beta", "Dockerfile"]))
    end

    test "errors when the directory has no packages/ subdir" do
      src = sandbox_dir("dockd-local-empty")
      File.mkdir_p!(src)
      dest = sandbox_dir("dockd-local-empty-dest")

      assert {:error, err} = Packages.install_from_path(dest, src)
      assert err.phase === :fetch
      assert err.message =~ "no top-level packages/ directory"
    end
  end

  describe "Dockd.install_packages/3" do
    test "installs from a local directory when the ref is an existing dir" do
      src = sandbox_dir("dockd-dispatch-local")
      dest = sandbox_dir("dockd-dispatch-local-dest")

      add_package(src, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))

      assert {:ok, ["alpha"]} = Dockd.install_packages(dest, src)
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
                 Dockd.install_packages(dest, "file://" <> repo,
                   staging_root: staging(),
                   git_path: git_path(),
                   git_env: git_env()
                 )

        assert File.exists?(Path.join([dest, "alpha", "package.json"]))
      end
    end

    test "a non-directory ref that is not cloneable fails on the git path" do
      dest = sandbox_dir("dockd-dispatch-bogus")

      assert {:error, err} =
               Dockd.install_packages(dest, "file:///nonexistent/repo.git",
                 staging_root: staging(),
                 git_path: git_path(),
                 git_env: git_env()
               )

      assert err.phase === :fetch
      assert err.message =~ "failed to clone"
    end
  end

  describe "Dockd.list_packages/2" do
    test "lists installed packages after an install" do
      src = sandbox_dir("dockd-list-src")
      root = sandbox_dir("dockd-list-root")

      add_package(src, "alpha", ~s({"instance_name": "alpha", "image": "busybox:1.37.0"}))
      assert {:ok, ["alpha"]} = Dockd.install_packages(root, src)

      assert [%{name: "alpha", path: path, spec: {:ok, spec}}] =
               Dockd.list_packages(root)

      assert path === Path.join(root, "alpha")
      assert spec.image === "busybox:1.37.0"
    end

    test "returns [] when the packages root does not exist" do
      assert Dockd.list_packages(sandbox_dir("dockd-list-missing")) === []
    end
  end

  describe "Dockd.new_package/3" do
    test "writes package.json and Dockerfile into the given directory" do
      dir = Path.join(sandbox_dir("dockd-new-pkg"), "greeter")

      assert {:ok, result} = Dockd.new_package(dir, "greeter", from: "busybox:1.37.0")

      assert result.instance_name === "greeter"
      assert result.path === dir
      refute result.overwrote?

      assert result.files === [
               Path.join(dir, "package.json"),
               Path.join(dir, "Dockerfile")
             ]

      assert File.read!(Path.join(dir, "Dockerfile")) === "FROM busybox:1.37.0\n"
    end

    # The scaffolder gates on the same rules a loaded package is held to: it
    # encodes the document, then runs it back through the Parser and Normalizer
    # before writing. Nothing should reach disk when that gate rejects it.
    test "rejects mutually exclusive env options and writes nothing" do
      dir = Path.join(sandbox_dir("dockd-new-env-exclusive"), "greeter")

      assert {:error, err} =
               Dockd.new_package(dir, "greeter", env: [{"FOO", value: "a", default: "b"}])

      assert err.phase === :validate
      assert err.message =~ "cannot coexist"
      refute File.exists?(Path.join(dir, "package.json"))
    end

    # Regression: the encoder's own copy of the name rules omitted the dockd-
    # prefix check, so this scaffolded a package that failed when applied.
    test "rejects an instance name that already carries the dockd- prefix" do
      dir = Path.join(sandbox_dir("dockd-new-prefixed"), "greeter")

      assert {:error, err} = Dockd.new_package(dir, "dockd-greeter")
      assert err.phase === :validate
      assert err.message =~ "must not include the dockd- prefix"
      refute File.exists?(Path.join(dir, "package.json"))
    end

    test "the generated package parses as a Spec" do
      dir = Path.join(sandbox_dir("dockd-new-parse"), "greeter")
      assert {:ok, _} = Dockd.new_package(dir, "greeter", image: "dockd-greeter:1")

      root = Path.dirname(dir)

      assert [%{name: "greeter", spec: {:ok, spec}}] =
               Dockd.list_packages(root)

      assert spec.image === "dockd-greeter:1"
      assert spec.instance_name === "greeter"
      assert spec.build === %{dockerfile: Path.join(dir, "Dockerfile")}
    end

    # The name used to default to the directory basename, which for a relative
    # `dir` such as "." was really the calling process's working directory.
    test "uses the instance name it is given, not the directory basename" do
      dir = Path.join(sandbox_dir("dockd-new-basename"), "webapp")
      assert {:ok, %{instance_name: "chosen"}} = Dockd.new_package(dir, "chosen")

      decoded = JSON.decode!(File.read!(Path.join(dir, "package.json")))
      assert decoded["instance_name"] === "chosen"
      assert decoded["image"] === "dockd-chosen:latest"
    end

    test "writes a package.json a human can edit" do
      dir = Path.join(sandbox_dir("dockd-new-pretty"), "greeter")
      assert {:ok, _} = Dockd.new_package(dir, "greeter")

      body = File.read!(Path.join(dir, "package.json"))

      assert body =~ ~s(  "instance_name": "greeter")
      assert length(String.split(body, "\n")) > 3
    end

    test "refuses to overwrite an existing directory without :force" do
      dir = Path.join(sandbox_dir("dockd-new-collide"), "greeter")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "keep.txt"), "mine")

      assert {:error, err} = Dockd.new_package(dir, "greeter")

      assert err.phase === :generate
      assert err.message =~ "already exists"
      assert File.read!(Path.join(dir, "keep.txt")) === "mine"
      refute File.exists?(Path.join(dir, "package.json"))
    end

    test "replaces an existing directory with force: true" do
      dir = Path.join(sandbox_dir("dockd-new-force"), "greeter")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "stale.txt"), "old")

      assert {:ok, %{overwrote?: true}} = Dockd.new_package(dir, "greeter", force: true)

      refute File.exists?(Path.join(dir, "stale.txt"))
      assert File.exists?(Path.join(dir, "package.json"))
    end

    test "writes nothing when the options are invalid" do
      dir = Path.join(sandbox_dir("dockd-new-invalid"), "greeter")

      assert {:error, err} =
               Dockd.new_package(dir, "greeter", env: [{"FOO", value: "a", optional: true}])

      assert err.phase === :validate
      refute File.exists?(dir)
    end

    test "writes nothing when the instance name is unusable" do
      dir = Path.join(sandbox_dir("dockd-new-badname"), "greeter")

      assert {:error, err} = Dockd.new_package(dir, "not a name")

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

  defp staging, do: sandbox_dir("dockd-staging")

  # The library never discovers git; a test may, to know what to pass in.
  defp git_path, do: System.find_executable("git")

  defp git_env, do: %{"HOME" => System.user_home!()}
end
