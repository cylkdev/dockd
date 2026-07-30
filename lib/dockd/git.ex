defmodule Dockd.Git do
  @moduledoc """
  Clones git repositories on the host and hands them to `Dockd.FileCopy` for upload.

  Each spec is a `%{url, dest, ref?, depth?, history?}` map. Cloning happens on the host
  using the `git` executable at `git_path`, with exactly the environment in `git_env` —
  neither is discovered from the calling process. That means credentials, `~/.gitconfig`,
  and any SSH agent are inputs the caller supplies deliberately: pass the relevant
  variables (`HOME`, `SSH_AUTH_SOCK`, `GIT_SSH_COMMAND`, …) in `git_env` if a clone needs
  them, and omit them to clone in isolation. `GIT_TERMINAL_PROMPT=0` is always forced, so a
  private URL fails fast instead of blocking on an invisible credential prompt.

  All repos in a single `download_repos_to_host/7` call are cloned into one per-call
  subdirectory of `temp_root`, then forwarded to `Dockd.FileCopy.copy_files/7` as a list of
  copy specs. That delegates the upload to a single tar + `Docker.put_archive/4` + one
  in-container `mv` pass, so the container sees one batched copy regardless of how many
  repos are listed.

  By default a shallow clone (`depth: 1`) is used and the `.git` directory is excluded from
  the upload (`history: false`). Set `history: true` to ship the full repository history
  alongside the working tree, and tune `depth` for partial-history mirrors.

  Errors raised by the cloning phase are tagged `:fetch`. Errors raised by the subsequent
  upload (delegated to `Dockd.FileCopy`) are tagged `:copy` and propagate through
  unchanged. The caller (the provisioner) attaches a hydrated `Dockd.Instance` to the
  returned error so it can be cleaned up with `Dockd.destroy/3`.

  ## Responsibilities

    - Validate that `git_path` names an executable before any side effects
    - Shallow-clone each repo into `<host_tmp>/<index>`, optionally checking out a `:ref`
    - Strip `.git/` from the staged tree unless `:history` is true
    - Build copy specs (`%{src, dest}`) and delegate the upload to `Dockd.FileCopy`
    - Tear down the host tempdir on the host whether the fetch succeeds or fails
  """

  alias Dockd.Error
  alias Dockd.HostTool

  @doc """
  Clones the given git repos on the host and uploads them into a container.

  `specs` is a list of `%{url, dest, ref?, depth?, history?}` maps. Each repo is
  cloned into a fresh per-call subdirectory of `temp_root` — shallow (`depth: 1`)
  by default, with `.git` stripped unless `history: true` — and then all repos are
  forwarded to `Dockd.FileCopy.copy_files/7` as a single batched upload into
  `container_id`. The staging dir is always removed afterwards.

  Required arguments:

    - `temp_root` — absolute host directory to stage clones under
    - `git_path` — absolute path to the `git` executable
    - `git_env` — the environment to run `git` in, as a `%{name => value}` map.
      `%{}` runs git with no inherited environment at all
    - `docker_options` — Docker connection options for the upload

  `opts` is forwarded to `Dockd.FileCopy.copy_files/7` for the upload leg.

  Returns `:ok` (also for an empty `specs` list, with no side effects) or
  `{:error, %Dockd.Error{}}` — clone failures are tagged `:fetch`, upload
  failures `:copy`.
  """
  @spec download_repos_to_host(
          [map()],
          binary(),
          Path.t(),
          Path.t(),
          %{optional(binary()) => binary()},
          keyword(),
          keyword()
        ) :: :ok | {:error, Error.t()}
  def download_repos_to_host(specs, container_id, temp_root, git_path, git_env, docker_options, opts \\ [])

  def download_repos_to_host([], _container_id, _temp_root, _git_path, _git_env, _docker_options, _opts),
    do: :ok

  def download_repos_to_host(specs, container_id, temp_root, git_path, git_env, docker_options, opts) do
    with :ok <- ensure_git(git_path) do
      host_tmp = staging_dir(temp_root)

      try do
        with :ok <- make_staging_dir(host_tmp),
             {:ok, copies} <- clone_all(specs, host_tmp, git_path, git_env) do
          Dockd.FileCopy.copy_files(
            copies,
            container_id,
            temp_root,
            Keyword.get(opts, :tar_path),
            Keyword.get(opts, :tar_env),
            docker_options,
            opts
          )
        end
      after
        File.rm_rf(host_tmp)
      end
    end
  end

  # Type and presence of git_path/git_env are established by
  # Provisioner.validate_tools/1 before the only call site reaches here, so the
  # one thing left to check is that the path actually names an executable.
  defp ensure_git(git_path) do
    case HostTool.executable(git_path, "git", "cloning :repos") do
      :ok -> :ok
      {:error, message} -> {:error, %Error{phase: :fetch, message: message}}
    end
  end

  defp staging_dir(temp_root),
    do: Path.join(temp_root, "dockd-fetch-#{System.unique_integer([:positive])}")

  defp clone_all(specs, host_tmp, git_path, git_env) do
    reduced =
      specs
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, acc} ->
        case clone_one(spec, index, host_tmp, git_path, git_env) do
          {:ok, copy_spec} -> {:cont, {:ok, [copy_spec | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, acc} <- reduced, do: {:ok, Enum.reverse(acc)}
  end

  defp clone_one(%{url: url, dest: dest} = spec, index, host_tmp, git_path, git_env) do
    clone_dir = Path.join(host_tmp, Integer.to_string(index))

    with :ok <- clone(url, spec, clone_dir, git_path, git_env),
         :ok <- maybe_strip_git(clone_dir, Map.get(spec, :history, false)) do
      {:ok, %{src: clone_dir, dest: dest}}
    end
  end

  defp clone(url, spec, target, git_path, git_env) do
    depth = Map.get(spec, :depth, 1)
    ref = Map.get(spec, :ref)

    args =
      ["clone", "--quiet"]
      |> maybe_arg(depth, &["--depth", to_string(&1)])
      |> maybe_arg(ref, &["--branch", &1])
      |> Kernel.++([url, target])

    # cd: the staging dir so a relative path in git_env or a repo-local config
    # cannot be resolved against whatever directory the caller happened to be in.
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

  # GIT_TERMINAL_PROMPT=0 is forced, never merged from the caller: a credential
  # prompt inside a provisioning run has no terminal to read from and would hang
  # with no timeout.
  defp env_list(git_env) do
    git_env
    |> Map.put("GIT_TERMINAL_PROMPT", "0")
    |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp maybe_arg(args, nil, _build), do: args
  defp maybe_arg(args, value, build), do: args ++ build.(value)

  defp maybe_strip_git(_dir, true), do: :ok

  defp maybe_strip_git(clone_dir, false) do
    _ = File.rm_rf(Path.join(clone_dir, ".git"))
    :ok
  end

  defp make_staging_dir(host_tmp) do
    case File.mkdir_p(host_tmp) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Error.docker_phase_error(:fetch, "could not create staging dir", reason, nil)}
    end
  end
end
