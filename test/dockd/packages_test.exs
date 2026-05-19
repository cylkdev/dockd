defmodule Dockd.PackagesTest do
  use ExUnit.Case, async: true

  alias Dockd.Packages

  describe "resolve_path/1" do
    test "bare name resolves to priv/packages/<name>/package.json" do
      path = Packages.resolve_path("claude_code")

      assert Path.basename(path) === "package.json"
      assert Path.basename(Path.dirname(path)) === "claude_code"

      assert path ===
               Path.join([Packages.packages_root(), "claude_code", "package.json"])
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
      results = Packages.list()
      assert is_list(results)

      Enum.each(results, fn entry ->
        assert is_binary(entry.name)
        assert is_binary(entry.path)
        assert match?({:ok, %Dockd.Spec{}}, entry.spec) or match?({:error, _}, entry.spec)
      end)
    end

    test "returns {:ok, spec} for packages that reference unset env vars" do
      results = Packages.list()

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

      add_package(repo, "alpha", ~s({"name": "alpha", "image": "busybox:1.37.0"}))

      add_package(repo, "beta", ~s({"name": "beta", "image": "busybox:1.37.0"}),
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

      add_package(repo, "alpha", ~s({"name": "alpha", "image": "busybox:1.37.0"}))
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
end
