defmodule Dockd.Git do
  @moduledoc """
  Clones git repositories on the host and hands them to `Dockd.FileCopy` for upload.

  Each spec is a `%{url, dest, ref?, depth?, history?}` map. Cloning happens on the host
  using the host's `git` binary - so HTTPS or SSH credentials, SSH agents, and `~/.gitconfig`
  are reused as-is. All repos in a single `download_repos_to_host/3` call are cloned into
  one per-call host tempdir, then forwarded to `Dockd.FileCopy.copy_files/3` as a list of
  copy specs. That delegates the upload to a single tar + `Docker.put_archive/4` + one
  in-container `mv` pass, so the container sees one batched copy regardless of how many
  repos are listed.

  By default a shallow clone (`depth: 1`) is used and the `.git` directory is excluded from
  the upload (`history: false`). Set `history: true` to ship the full repository history
  alongside the working tree, and tune `depth` for partial-history mirrors.

  Errors raised by the cloning phase are tagged `:fetch`. Errors raised by the subsequent
  upload (delegated to `Dockd.FileCopy`) are tagged `:copy` and propagate through
  unchanged. The caller (the provisioner) attaches a hydrated `Dockd.Instance` to the
  returned error so it can be cleaned up with `Dockd.destroy/1`.

  ## Responsibilities

    - Validate that the host's `git` binary is available before any side effects
    - Shallow-clone each repo into `<host_tmp>/<index>`, optionally checking out a `:ref`
    - Strip `.git/` from the staged tree unless `:history` is true
    - Build copy specs (`%{src, dest}`) and delegate the upload to `Dockd.FileCopy`
    - Tear down the host tempdir on the host whether the fetch succeeds or fails
  """

  alias Dockd.Error

  @spec download_repos_to_host([map()], binary(), keyword()) :: :ok | {:error, Error.t()}
  def download_repos_to_host([], _container_id, _docker_options), do: :ok

  def download_repos_to_host(specs, container_id, docker_options)
      when is_list(specs) and is_binary(container_id) and is_list(docker_options) do
    host_tmp =
      Path.join([
        System.tmp_dir!(),
        "dockd",
        "dockd-fetch-#{System.unique_integer([:positive])}"
      ])

    try do
      with :ok <- ensure_git(),
           :ok <- wrap(File.mkdir_p(host_tmp), "could not create staging dir"),
           {:ok, copies} <- clone_all(specs, host_tmp) do
        Dockd.FileCopy.copy_files(copies, container_id, docker_options)
      end
    after
      File.rm_rf(host_tmp)
    end
  end

  defp ensure_git do
    case System.find_executable("git") do
      nil ->
        {:error,
         %Error{
           phase: :fetch,
           message: "git not found on host PATH; install git or remove \"repos\" from package"
         }}

      _ ->
        :ok
    end
  end

  defp clone_all(specs, host_tmp) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, acc} ->
      case clone_one(spec, index, host_tmp) do
        {:ok, copy_spec} -> {:cont, {:ok, [copy_spec | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp clone_one(%{url: url, dest: dest} = spec, index, host_tmp) do
    clone_dir = Path.join(host_tmp, Integer.to_string(index))

    with :ok <- clone(url, spec, clone_dir),
         :ok <- maybe_strip_git(clone_dir, Map.get(spec, :history, false)) do
      {:ok, %{src: clone_dir, dest: dest}}
    end
  end

  defp clone(url, spec, target) do
    depth = Map.get(spec, :depth, 1)
    ref = Map.get(spec, :ref)

    args =
      ["clone", "--quiet"]
      |> maybe_arg(depth, &["--depth", to_string(&1)])
      |> maybe_arg(ref, &["--branch", &1])
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

  defp maybe_arg(args, nil, _build), do: args
  defp maybe_arg(args, value, build), do: args ++ build.(value)

  defp maybe_strip_git(_dir, true), do: :ok

  defp maybe_strip_git(clone_dir, false) do
    _ = File.rm_rf(Path.join(clone_dir, ".git"))
    :ok
  end

  defp wrap(:ok, _msg), do: :ok

  defp wrap({:error, reason}, msg),
    do: {:error, Error.docker_phase_error(:fetch, msg, reason, nil)}
end
