defmodule Dockd.GitTool do
  @moduledoc """
  Clones git repositories on the host and uploads them into a running container.

  Each spec is a `%{url, dest, ref?, depth?, history?}` map. Cloning happens on the host
  using the host's `git` binary — so HTTPS or SSH credentials, SSH agents, and `~/.gitconfig`
  are reused as-is. The clone runs in a tempdir and is tar-streamed into the container via
  `Docker.put_archive/4`; nothing about the host filesystem outside the tempdir is touched.

  By default a shallow clone (`depth: 1`) is used and the `.git` directory is excluded from
  the upload (`history: false`). Set `history: true` to ship the full repository history
  alongside the working tree, and tune `depth` for partial-history mirrors.

  Errors are tagged with phase `:fetch` and carry the partial `Dockd.Session` so the caller
  can clean up the container.

  ## Responsibilities

    - Validate that the host's `git` binary is available before any side effects
    - Shallow-clone each repo into a per-spec tempdir, optionally checking out a `:ref`
    - Strip `.git/` from the staged tree unless `:history` is true
    - Build a tar of the staged tree and `PUT` it into the container at `dirname(dest)`,
      after `mkdir -p`-ing that directory; the working tree appears as `basename(dest)`
    - Tear down the per-spec tempdir on the host whether the fetch succeeds or fails

  ## Examples

      iex> Dockd.GitTool.run([], %Dockd.Session{})
      :ok

  """

  alias Dockd.Error
  alias Dockd.Session

  @spec run([map()], Session.t()) :: :ok | {:error, Error.t()}
  def run([], _session), do: :ok

  def run(specs, %Session{} = session) when is_list(specs) do
    with :ok <- ensure_git(session) do
      Enum.reduce_while(specs, :ok, fn spec, :ok ->
        case fetch_one(spec, session) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp ensure_git(session) do
    case System.find_executable("git") do
      nil ->
        {:error,
         %Error{
           phase: :fetch,
           message: "git not found on host PATH; install git or remove \"repos\" from package",
           session: session
         }}

      _ ->
        :ok
    end
  end

  defp fetch_one(%{url: url, dest: dest} = spec, session) do
    parent = container_dirname(dest)
    base = Path.basename(dest)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dockd-fetch-#{System.unique_integer([:positive])}"
      )

    try do
      with :ok <- File.mkdir_p(tmp_dir) |> wrap("could not create staging dir", session),
           clone_dir <- Path.join(tmp_dir, base),
           :ok <- clone(url, spec, clone_dir, session),
           :ok <- maybe_strip_git(clone_dir, Map.get(spec, :history, false)),
           {:ok, tar} <- tar_dir(tmp_dir, base, session),
           :ok <- ensure_parent(parent, session),
           :ok <- upload(tar, parent, session) do
        :ok
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp clone(url, spec, target, session) do
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
           session
         )}
    end
  end

  defp maybe_arg(args, nil, _build), do: args
  defp maybe_arg(args, value, build), do: args ++ build.(value)

  defp maybe_strip_git(_dir, true), do: :ok

  defp maybe_strip_git(clone_dir, false) do
    File.rm_rf(Path.join(clone_dir, ".git"))
    :ok
  end

  defp tar_dir(tmp_dir, entry, session) do
    args =
      case :os.type() do
        {:unix, :darwin} ->
          ["--no-xattrs", "--no-acls", "--no-mac-metadata", "-C", tmp_dir, "-cf", "-", entry]

        _ ->
          ["-C", tmp_dir, "-cf", "-", entry]
      end

    case System.cmd("tar", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error,
         Error.docker_phase_error(
           :fetch,
           "failed to tar #{entry}",
           %{status: code, body: output},
           session
         )}
    end
  end

  defp ensure_parent("/", _session), do: :ok

  defp ensure_parent(parent, %Session{container_id: id, docker_options: opts} = session) do
    case Docker.exec_run_with_status(id, ["mkdir", "-p", parent], opts) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, output: output}} ->
        {:error,
         Error.docker_phase_error(
           :fetch,
           "failed to mkdir #{parent}",
           %{status: code, body: output},
           session
         )}

      {:error, reason} ->
        {:error, Error.docker_phase_error(:fetch, "failed to mkdir #{parent}", reason, session)}
    end
  end

  defp upload(tar, parent, %Session{container_id: id, docker_options: opts} = session) do
    case Docker.put_archive(id, parent, tar, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error,
         Error.docker_phase_error(
           :fetch,
           "failed to upload archive to #{parent}",
           reason,
           session
         )}
    end
  end

  defp container_dirname(path) do
    case Path.dirname(path) do
      "" -> "/"
      "." -> "/"
      dir -> dir
    end
  end

  defp wrap(:ok, _msg, _session), do: :ok

  defp wrap({:error, reason}, msg, session),
    do: {:error, Error.docker_phase_error(:fetch, msg, reason, session)}
end
