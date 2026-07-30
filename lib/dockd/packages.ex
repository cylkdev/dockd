defmodule Dockd.Packages do
  @moduledoc """
  Storage layer for dockd packages.

  A package is a directory under a packages `root` that contains a `package.json`
  (the serialized `Dockd.Spec`) plus any supporting files the spec references
  (typically a `Dockerfile`). The package's identity is its directory name.

  `root` is the first argument of every function here. There is no configured
  default and no `packages_root/0`: the root is not read from an environment
  variable, from application config, or from the home directory, because which
  directory a package is installed into or deleted from is exactly the kind of
  input a caller must state.

  This module owns lookup and installation:

    - `resolve_path/3` — turn the user-facing reference passed to
      `Dockd.apply_package/7` into a concrete path to a `package.json`.
    - `list/2` — enumerate the packages already installed under `root`.
    - `install_from_git/6` — clone a remote git repository and copy
      every `<repo>/packages/<name>/` directory containing a `package.json`
      into `root`.
    - `install_from_path/3` — the same copy step against a local directory,
      with no clone.
    - `new/3` — scaffold a package's files (`package.json` + `Dockerfile`) from
      caller options, so nobody has to hand-write them.
    - `delete/3` — remove an installed package from `root`.

  Both installers share one implementation, so they agree on what counts as a
  package and on the `{:ok, [name]}` / `:fetch`-tagged-error contract.
  `Dockd.install_packages/3` picks between them for the caller.

  Remote installs run the `git` executable at `git_path` with exactly the
  environment in `git_env` (same approach as `Dockd.Git`), so credentials and
  `~/.gitconfig` are reached only if the caller passes the variables that point
  at them. The clone is shallow (`--depth 1`) and the staging dir is always
  cleaned up.
  """

  alias Dockd.Error
  alias Dockd.HostTool
  alias Dockd.Spec
  alias Dockd.Spec.Encoder
  alias Dockd.Spec.Normalizer
  alias Dockd.Spec.Parser

  @package_filename "package.json"
  @packages_subdir "packages"

  @doc """
  Resolves the reference passed to `Dockd.apply_package/7` into a path to a
  `package.json` file.

    - any string ending in `.json` is treated as a literal file path
    - any other string containing `/` is treated as a package directory
      and joined with `"package.json"`
    - any other string is resolved against `<root>/<name>/package.json`
  """
  @spec resolve_path(Path.t(), binary(), keyword()) :: Path.t()
  def resolve_path(root, ref, _opts \\ []) when is_binary(ref) do
    cond do
      String.ends_with?(ref, ".json") ->
        ref

      String.contains?(ref, "/") ->
        Path.join(ref, @package_filename)

      true ->
        Path.join([root, ref, @package_filename])
    end
  end

  @doc """
  Lists every installed package under `root`.

  A subdirectory is considered an installed package when it contains a
  readable `package.json`. The spec is parsed eagerly so callers can
  show metadata (image, shell) or surface a parse error per package.

  Returns a list of maps sorted by `:name`:

      %{name: binary(), path: Path.t(),
        spec: {:ok, Spec.t()} | {:error, Error.t()}}

  When `root` does not exist, returns `[]`.
  """
  @spec list(Path.t(), keyword()) :: [
          %{
            name: binary(),
            path: Path.t(),
            spec: {:ok, Spec.t()} | {:error, Error.t()}
          }
        ]
  def list(root, _opts \\ []) when is_binary(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&{&1, Path.join(root, &1)})
        |> Enum.filter(fn {_name, path} -> File.dir?(path) end)
        |> Enum.filter(fn {_name, path} ->
          File.exists?(Path.join(path, @package_filename))
        end)
        |> Enum.map(fn {name, path} ->
          %{
            name: name,
            path: path,
            spec: load_metadata_spec(Path.join(path, @package_filename))
          }
        end)

      {:error, _reason} ->
        []
    end
  end

  defp load_metadata_spec(json_path) do
    with {:ok, decoded} <- Parser.parse_file(json_path),
         {:ok, attrs} <- Normalizer.normalize(decoded, Path.dirname(json_path)) do
      Spec.from_attrs(attrs)
    end
  end

  @doc """
  Clones a git repository and installs every package found under its
  `packages/` directory into `root`.

  A subdirectory is considered a package when it contains a readable
  `package.json` that parses as a valid `Dockd.Spec`. Each installed
  package keeps its source folder name (e.g. `<repo>/packages/foo/` becomes
  `<root>/foo/`). An existing target directory is removed and replaced.

  Required arguments:

    - `root` — where packages are installed
    - `url` — the repository to clone
    - `staging_root` — absolute host directory to clone into before copying
    - `git_path` — absolute path to the `git` executable
    - `git_env` — the environment to run `git` in, as a `%{name => value}` map

  Options:

    - `:ref` — git branch or tag to clone. Omitting it clones the remote's
      default branch, which makes the result non-reproducible; pass it to pin.
    - `:packages_subdir` — the subdirectory of the repo to read packages from.
      Defaults to `"packages"`.

  Returns `{:ok, [name]}` with the installed package names, or
  `{:error, %Dockd.Error{}}` tagged with phase `:fetch`.
  """
  @spec install_from_git(
          Path.t(),
          binary(),
          Path.t(),
          Path.t(),
          %{optional(binary()) => binary()},
          keyword()
        ) :: {:ok, [binary()]} | {:error, Error.t()}
  def install_from_git(root, url, staging_root, git_path, git_env, opts \\ [])
      when is_binary(root) and is_binary(url) do
    ref = Keyword.get(opts, :ref)
    normalized_url = normalize_url(url)

    with :ok <- ensure_git(git_path),
         :ok <- ensure_env(git_env),
         {:ok, tmp} <- staging_dir(staging_root) do
      try do
        with :ok <- make_staging_dir(tmp),
             :ok <- clone(normalized_url, ref, tmp, git_path, git_env) do
          install_from_clone(tmp, root, opts)
        end
      after
        File.rm_rf(tmp)
      end
    end
  end

  @doc """
  Installs every package under a local directory's `packages/` subdir into `root`.

  Identical to `install_from_git/6` without the clone: `dir` must contain a
  `packages/<name>/` tree where each package dir holds a `package.json` that
  parses as a `Dockd.Spec`. Returns `{:ok, [name]}` or a `:fetch`-tagged
  `Dockd.Error`.

  Options:

    - `:packages_subdir` — the subdirectory of `dir` to read packages from.
      Defaults to `"packages"`.
  """
  @spec install_from_path(Path.t(), binary(), keyword()) ::
          {:ok, [binary()]} | {:error, Error.t()}
  def install_from_path(root, dir, opts \\ []) when is_binary(root) and is_binary(dir) do
    install_from_clone(dir, root, opts)
  end

  @doc """
  Deletes an installed package from `root`.

  `name` must be a bare package name — the directory name under `root`. Paths
  (`a/b`), `.json` references, and empty strings are rejected with a `:validate`
  error so this can never remove anything outside `root`.

  Idempotent: a package that is not installed returns `:ok`. A directory that
  exists but holds no `package.json` is not a package and is refused with a
  `:destroy` error rather than removed.
  """
  @spec delete(Path.t(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def delete(root, name, opts \\ [])
      when is_binary(root) and is_binary(name) and is_list(opts) do
    with :ok <- check_bare_name(name) do
      dir = Path.join(root, name)

      cond do
        not File.exists?(dir) ->
          :ok

        not File.exists?(Path.join(dir, @package_filename)) ->
          {:error,
           %Error{
             phase: :destroy,
             message: "#{dir} has no package.json; refusing to delete a non-package directory"
           }}

        true ->
          case File.rm_rf(dir) do
            {:ok, _files} ->
              :ok

            {:error, reason, file} ->
              {:error,
               Error.docker_phase_error(
                 :destroy,
                 "could not delete package #{name}",
                 %{reason: reason, file: file},
                 nil
               )}
          end
      end
    end
  end

  defp check_bare_name(name) do
    if name === "" or String.contains?(name, "/") or String.ends_with?(name, ".json") do
      {:error,
       %Error{
         phase: :validate,
         message: "delete takes a bare package name, got: #{inspect(name)}"
       }}
    else
      :ok
    end
  end

  @doc """
  Scaffolds a new package into `dir`.

  `dir` **is** the package directory — files are written directly into it, with
  no path joining — so this works for a packages-root entry, a
  `packages/<name>/` entry in a shareable set, or anywhere else.

  Writes two files: `package.json` and a `Dockerfile` that the package always
  references as its build. `:image` is therefore the tag the build produces,
  and `:from` sets the Dockerfile's base image.

  Only the keys you pass are emitted; omitted keys are absent from the
  document.

  `instance_name` is the container name the package creates. It is a required
  argument rather than a default derived from `dir`'s basename: with a relative
  `dir` such as `"."` that basename came from the calling process's working
  directory, so the package's identity depended on where the caller stood.

  Options:

    - `:image` — build tag. Defaults to `Dockd.Spec.Encoder.default_image/1`.
    - `:from` — base image for the Dockerfile. Defaults to
      `Dockd.Spec.Encoder.default_from/0`.
    - `:dockerfile` — a complete Dockerfile body, used instead of `:from`.
    - `:build` — extra Docker build keys merged over `{"dockerfile": "Dockerfile"}`.
    - `:force` — replace an existing directory. Defaults to `false`.
    - `:description`, `:shell`, `:env`, `:mounts`, `:repos`, `:copy`, `:steps`,
      `:labels` — written through to the document.

  The document is validated with the same parse-and-normalize pass that
  `Dockd.apply_package/7` uses **before** anything is written, so a rejected
  call never leaves a half-written package behind.

  ## Examples

      {:ok, %{instance_name: "greeter", files: files}} =
        Dockd.Packages.new("./my-recipes/packages/greeter", "greeter",
          image: "dockd-greeter:1",
          from: "busybox:1.37.0"
        )
  """
  @spec new(Path.t(), binary(), keyword()) ::
          {:ok,
           %{
             instance_name: binary(),
             path: Path.t(),
             files: [Path.t()],
             overwrote?: boolean()
           }}
          | {:error, Error.t()}
  def new(dir, instance_name, opts \\ [])
      when is_binary(dir) and is_binary(instance_name) and is_list(opts) do
    existed? = File.exists?(dir)

    package_path = Path.join(dir, @package_filename)
    dockerfile_path = Path.join(dir, Encoder.dockerfile_name())

    # Both documents are built and validated before anything is written, so a
    # rejected :dockerfile cannot leave a package.json behind with no Dockerfile.
    with {:ok, document} <- Encoder.document(instance_name, opts),
         {:ok, dockerfile} <- Encoder.dockerfile(opts),
         json = Encoder.encode(document),
         :ok <- validate_document(json, dir),
         :ok <- check_collision(dir, existed?, Keyword.get(opts, :force, false)),
         :ok <- reset_dir(dir, existed?),
         :ok <- write_file(package_path, json),
         :ok <- write_file(dockerfile_path, dockerfile) do
      {:ok,
       %{
         instance_name: instance_name,
         path: dir,
         files: [package_path, dockerfile_path],
         overwrote?: existed?
       }}
    end
  end

  # The generated document goes through the same gate every package passes on
  # load, so the scaffolder can never emit something apply_package/2 rejects.
  defp validate_document(json, dir) do
    with {:ok, decoded} <- Parser.parse(json),
         {:ok, _attrs} <- Normalizer.normalize(decoded, dir) do
      :ok
    end
  end

  defp check_collision(dir, true, false) do
    {:error,
     %Error{
       phase: :generate,
       message: "#{dir} already exists; pass force: true to replace it"
     }}
  end

  defp check_collision(_dir, _existed?, _force?), do: :ok

  defp reset_dir(dir, existed?) do
    with :ok <- clear_dir(dir, existed?) do
      make_dir(dir)
    end
  end

  defp clear_dir(_dir, false), do: :ok

  defp clear_dir(dir, true) do
    case File.rm_rf(dir) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        {:error,
         %Error{
           phase: :generate,
           message: "could not replace #{path}: #{:file.format_error(reason)}"
         }}
    end
  end

  defp make_dir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(:generate, "could not create package dir #{dir}", reason, nil)}
    end
  end

  defp write_file(path, body) do
    case File.write(path, body) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Error.docker_phase_error(:generate, "could not write #{path}", reason, nil)}
    end
  end

  defp install_from_clone(clone_dir, dest_dir, opts) do
    subdir = Keyword.get(opts, :packages_subdir, @packages_subdir)
    packages_dir = Path.join(clone_dir, subdir)

    if File.dir?(packages_dir) do
      case File.mkdir_p(dest_dir) do
        :ok ->
          packages_dir
          |> File.ls!()
          |> Enum.map(&{&1, Path.join(packages_dir, &1)})
          |> Enum.filter(fn {_name, path} -> File.dir?(path) end)
          |> Enum.filter(fn {_name, path} ->
            File.exists?(Path.join(path, @package_filename))
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
         message: "repository has no top-level #{subdir}/ directory"
       }}
    end
  end

  defp install_each(candidates, dest_dir) do
    reduced =
      Enum.reduce_while(candidates, {:ok, []}, fn {name, src}, {:ok, acc} ->
        with {:ok, _spec} <- load_metadata_spec(Path.join(src, @package_filename)),
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

    with {:ok, acc} <- reduced, do: {:ok, Enum.reverse(acc)}
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

  defp ensure_git(git_path),
    do: fetch_check(HostTool.executable(git_path, "git", "installing from git"))

  defp ensure_env(env), do: fetch_check(HostTool.env(env, "git"))

  defp staging_dir(staging_root) do
    with :ok <- fetch_check(HostTool.staging_root(staging_root, "staging_root")) do
      {:ok, Path.join(staging_root, "dockd-pkg-#{System.unique_integer([:positive])}")}
    end
  end

  defp fetch_check(:ok), do: :ok
  defp fetch_check({:error, message}), do: {:error, %Error{phase: :fetch, message: message}}

  defp clone(url, ref, target, git_path, git_env) do
    args =
      ["clone", "--quiet", "--depth", "1"]
      |> maybe_branch(ref)
      |> Kernel.++([url, target])

    cmd_opts = [
      stderr_to_stdout: true,
      cd: Path.dirname(target),
      env: env_list(git_env)
    ]

    case System.cmd(git_path, args, cmd_opts) do
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

  # Forced, not merged: a credential prompt here would block with no terminal
  # to answer it and no timeout.
  defp env_list(git_env) do
    git_env
    |> Map.put("GIT_TERMINAL_PROMPT", "0")
    |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)
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
