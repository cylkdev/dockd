defmodule Dockd.Packages do
  @moduledoc """
  Storage layer for dockd packages.

  A package is a directory under the configured packages root that contains a
  `package.json` (the serialized `Dockd.Spec`) plus any supporting files the
  spec references (typically a `Dockerfile`). The package's identity is its
  directory name.

  This module owns lookup and installation:

    - `resolve_path/2` — turn the user-facing reference passed to
      `Dockd.apply_package/2` into a concrete path to a `package.json`.
    - `list/1` — enumerate the packages already installed under the root.
    - `install_from_git/2` — clone a remote git repository and copy
      every `<repo>/packages/<name>/` directory containing a `package.json`
      into the configured packages root.
    - `install_from_path/2` — the same copy step against a local directory,
      with no clone.

  Both installers share one implementation, so they agree on what counts as a
  package and on the `{:ok, [name]}` / `:fetch`-tagged-error contract.
  `Dockd.install_packages/2` picks between them for the caller.

  Remote installs use the host `git` binary (same approach as
  `Dockd.Git`) so HTTPS/SSH credentials and `~/.gitconfig` are reused
  as-is. The clone is shallow (`--depth 1`) and the staging tempdir is
  always cleaned up.
  """

  alias Dockd.Error
  alias Dockd.Spec
  alias Dockd.Spec.Normalizer
  alias Dockd.Spec.Parser

  @doc """
  Resolves the reference passed to `Dockd.apply_package/2` into a path to a
  `package.json` file.

    - any string ending in `.json` is treated as a literal file path
    - any other string containing `/` is treated as a package directory
      and joined with `"package.json"`
    - any other string is resolved against `<packages_root>/<name>/package.json`
  """
  @spec resolve_path(binary()) :: Path.t()
  @spec resolve_path(binary(), keyword()) :: Path.t()
  def resolve_path(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    cond do
      String.ends_with?(ref, ".json") ->
        ref

      String.contains?(ref, "/") ->
        Path.join(ref, "package.json")

      true ->
        Path.join([packages_root(opts), ref, "package.json"])
    end
  end

  @doc """
  Returns the configured package root.

  Resolved from the first source that supplies a value: `opts[:packages_path]`,
  then `DOCKD_PACKAGES_PATH`, then `config :dockd, packages_path: ...`.
  Defaults to `~/.dockd/packages`.
  """
  @spec packages_root() :: Path.t()
  @spec packages_root(keyword()) :: Path.t()
  def packages_root(opts \\ []) do
    Keyword.get(opts, :packages_path) ||
      System.get_env("DOCKD_PACKAGES_PATH") ||
      Application.get_env(:dockd, :packages_path) ||
      Path.join(System.user_home!(), ".dockd/packages")
  end

  @doc """
  Lists every installed package under the configured packages root.

  A subdirectory is considered an installed package when it contains a
  readable `package.json`. The spec is parsed eagerly so callers can
  show metadata (image, shell) or surface a parse error per package.

  Returns a list of maps sorted by `:name`:

      %{name: binary(), path: Path.t(),
        spec: {:ok, Spec.t()} | {:error, Error.t()}}

  When the packages root does not exist, returns `[]`.
  """
  @spec list() :: [
          %{
            name: binary(),
            path: Path.t(),
            spec: {:ok, Spec.t()} | {:error, Error.t()}
          }
        ]
  @spec list(keyword()) :: [
          %{
            name: binary(),
            path: Path.t(),
            spec: {:ok, Spec.t()} | {:error, Error.t()}
          }
        ]
  def list(opts \\ []) do
    root = packages_root(opts)

    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&{&1, Path.join(root, &1)})
        |> Enum.filter(fn {_name, path} -> File.dir?(path) end)
        |> Enum.filter(fn {_name, path} ->
          File.exists?(Path.join(path, "package.json"))
        end)
        |> Enum.map(fn {name, path} ->
          %{
            name: name,
            path: path,
            spec: load_metadata_spec(Path.join(path, "package.json"))
          }
        end)

      {:error, _reason} ->
        []
    end
  end

  defp load_metadata_spec(json_path) do
    with {:ok, decoded} <- Parser.parse_file(json_path),
         {:ok, attrs} <- Normalizer.normalize(decoded, Path.dirname(json_path)) do
      {:ok, Spec.from_attrs(attrs)}
    end
  end

  @doc """
  Clones a git repository and installs every package found under its
  `packages/` directory into the configured packages root.

  A subdirectory is considered a package when it contains a readable
  `package.json` that parses as a valid `Dockd.Spec`. Each installed
  package keeps its source folder name (e.g. `<repo>/packages/foo/` becomes
  `<packages_root>/foo/`). An existing target directory is removed and replaced.

  Options:

    - `:ref` — git branch or tag to clone (defaults to the remote's
      default branch).
    - `:packages_path` — override the configured packages root.
    - `:dest_dir` — override the install root. Primarily used by tests.

  Returns `{:ok, [name]}` with the installed package names, or
  `{:error, %Dockd.Error{}}` tagged with phase `:fetch`.
  """
  @spec install_from_git(binary(), keyword()) ::
          {:ok, [binary()]} | {:error, Error.t()}
  def install_from_git(url, opts \\ []) when is_binary(url) do
    dest_dir = Keyword.get(opts, :dest_dir, packages_root(opts))
    ref = Keyword.get(opts, :ref)
    normalized_url = normalize_url(url)

    tmp =
      Path.join([
        System.tmp_dir!(),
        "dockd",
        "dockd-pkg-#{System.unique_integer([:positive])}"
      ])

    try do
      with :ok <- ensure_git(),
           :ok <- make_staging_dir(tmp),
           :ok <- clone(normalized_url, ref, tmp),
           {:ok, names} <- install_from_clone(tmp, dest_dir) do
        {:ok, names}
      end
    after
      File.rm_rf(tmp)
    end
  end

  @doc """
  Installs every package under a local directory's `packages/` subdir into
  the configured packages root.

  Identical to `install_from_git/2` without the clone: `dir` must contain a
  `packages/<name>/` tree where each package dir holds a `package.json` that
  parses as a `Dockd.Spec`. Returns `{:ok, [name]}` or a `:fetch`-tagged
  `Dockd.Error`.

  Options:

    - `:packages_path` — override the configured packages root.
    - `:dest_dir` — override the install root. Primarily used by tests.
  """
  @spec install_from_path(binary(), keyword()) ::
          {:ok, [binary()]} | {:error, Error.t()}
  def install_from_path(dir, opts \\ []) when is_binary(dir) do
    dest_dir = Keyword.get(opts, :dest_dir, packages_root(opts))
    install_from_clone(dir, dest_dir)
  end

  defp install_from_clone(clone_dir, dest_dir) do
    packages_dir = Path.join(clone_dir, "packages")

    if File.dir?(packages_dir) do
      case File.mkdir_p(dest_dir) do
        :ok ->
          packages_dir
          |> File.ls!()
          |> Enum.map(&{&1, Path.join(packages_dir, &1)})
          |> Enum.filter(fn {_name, path} -> File.dir?(path) end)
          |> Enum.filter(fn {_name, path} ->
            File.exists?(Path.join(path, "package.json"))
          end)
          |> install_each(dest_dir)

        {:error, reason} ->
          {:error,
           Error.docker_phase_error(
             :fetch,
             "could not create destination dir #{dest_dir}",
             reason,
             nil
           )}
      end
    else
      {:error,
       %Error{
         phase: :fetch,
         message: "repository has no top-level packages/ directory"
       }}
    end
  end

  defp install_each(candidates, dest_dir) do
    Enum.reduce_while(candidates, {:ok, []}, fn {name, src}, {:ok, acc} ->
      with {:ok, _spec} <- load_metadata_spec(Path.join(src, "package.json")),
           :ok <- copy_package(src, Path.join(dest_dir, name)) do
        {:cont, {:ok, [name | acc]}}
      else
        {:error, %Error{} = err} ->
          {:halt,
           {:error,
            %Error{
              err
              | phase: :fetch,
                message: "package #{inspect(name)}: #{err.message}"
            }}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp copy_package(src, dest) do
    _ = File.rm_rf(dest)

    case File.cp_r(src, dest) do
      {:ok, _files} ->
        :ok

      {:error, reason, file} ->
        {:error,
         Error.docker_phase_error(
           :fetch,
           "could not copy package to #{dest}",
           %{reason: reason, file: file},
           nil
         )}
    end
  end

  defp ensure_git do
    case System.find_executable("git") do
      nil ->
        {:error,
         %Error{
           phase: :fetch,
           message: "git not found on host PATH; install git to fetch remote packages"
         }}

      _ ->
        :ok
    end
  end

  defp clone(url, ref, target) do
    args =
      ["clone", "--quiet", "--depth", "1"]
      |> maybe_branch(ref)
      |> Kernel.++([url, target])

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error,
         Error.docker_phase_error(
           :fetch,
           "failed to clone #{url}",
           %{status: code, body: output},
           nil
         )}
    end
  end

  defp maybe_branch(args, nil), do: args
  defp maybe_branch(args, ref), do: args ++ ["--branch", ref]

  defp normalize_url("github.com/" <> _rest = shorthand),
    do: "https://" <> shorthand

  defp normalize_url(url), do: url

  defp make_staging_dir(tmp) do
    case File.mkdir_p(tmp) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Error.docker_phase_error(:fetch, "could not create staging dir", reason, nil)}
    end
  end
end
