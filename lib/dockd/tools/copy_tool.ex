defmodule Dockd.CopyTool do
  @moduledoc """
  Copies files and directories from the host into a running container.

  Each spec is a `%{src, dest, mode?, owner?}` map. `src` is a host path (file or directory);
  `dest` is the absolute path the entry should appear at inside the container. The contents
  of `src` are tar-streamed to the container via `Docker.put_archive/4`, so the host files
  are never modified — unlike a bind mount, the container has its own copy.

  Missing parent directories at `dest` are created with `mkdir -p` before the upload, so
  callers don't need to bake that into setup steps. After upload, `:mode` (e.g., `"0600"`)
  and `:owner` (e.g., `"root:root"`) are applied with `chmod`/`chown` exec calls.

  Errors are tagged with phase `:copy` and carry the partial `Dockd.Session` so the caller
  can clean up the container.

  ## Responsibilities

    - Validate that each `src` exists on the host before any side effects
    - Stage each `src` under `basename(dest)` in a per-spec tempdir, so the entry lands at
      the requested name even when `src` and `dest` differ
    - Build a tar of the staged entry and `PUT` it into the container at `dirname(dest)`,
      after `mkdir -p`-ing that directory
    - Apply optional `mode` and `owner` to the destination with exec calls inside the
      container
    - Tear down the per-spec tempdir on the host whether the copy succeeds or fails

  ## Examples

      iex> Dockd.CopyTool.run([], %Dockd.Session{})
      :ok

  """

  alias Dockd.Error
  alias Dockd.Session

  @spec run([map()], Session.t()) :: :ok | {:error, Error.t()}
  def run([], _session), do: :ok

  def run(specs, %Session{} = session) when is_list(specs) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      case copy_one(spec, session) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp copy_one(%{src: src, dest: dest} = spec, session) do
    parent = container_dirname(dest)
    base = Path.basename(dest)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dockd-copy-#{System.unique_integer([:positive])}"
      )

    try do
      with :ok <- File.mkdir_p(tmp_dir) |> wrap(:copy, "could not create staging dir", session),
           :ok <- stage(src, Path.join(tmp_dir, base), session),
           {:ok, tar} <- tar_dir(tmp_dir, base, session),
           :ok <- ensure_parent(parent, session),
           :ok <- upload(tar, parent, session),
           :ok <- maybe_chmod(Map.get(spec, :mode), dest, session),
           :ok <- maybe_chown(Map.get(spec, :owner), dest, session) do
        :ok
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp stage(src, staged, session) do
    expanded = Path.expand(src)

    cond do
      File.regular?(expanded) ->
        case File.cp(expanded, staged) do
          :ok -> :ok
          {:error, reason} -> error(:copy, "could not stage file #{src}", reason, session)
        end

      File.dir?(expanded) ->
        case File.cp_r(expanded, staged) do
          {:ok, _} -> :ok
          {:error, reason, path} -> error(:copy, "could not stage dir #{path}", reason, session)
        end

      true ->
        {:error,
         %Error{
           phase: :copy,
           message: "copy source does not exist: #{src}",
           session: session
         }}
    end
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
        error(:copy, "failed to tar #{entry}", %{status: code, body: output}, session)
    end
  end

  defp ensure_parent("/", _session), do: :ok

  defp ensure_parent(parent, %Session{container_id: id, docker_options: opts} = session) do
    case Docker.exec_run_with_status(id, ["mkdir", "-p", parent], opts) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, output: output}} ->
        error(
          :copy,
          "failed to mkdir #{parent}",
          %{status: code, body: output},
          session
        )

      {:error, reason} ->
        error(:copy, "failed to mkdir #{parent}", reason, session)
    end
  end

  defp upload(tar, parent, %Session{container_id: id, docker_options: opts} = session) do
    case Docker.put_archive(id, parent, tar, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> error(:copy, "failed to upload archive to #{parent}", reason, session)
    end
  end

  defp maybe_chmod(nil, _dest, _session), do: :ok

  defp maybe_chmod(mode, dest, %Session{container_id: id, docker_options: opts} = session) do
    case Docker.exec_run_with_status(id, ["chmod", "-R", mode, dest], opts) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, output: output}} ->
        error(
          :copy,
          "failed to chmod #{dest} to #{mode}",
          %{status: code, body: output},
          session
        )

      {:error, reason} ->
        error(:copy, "failed to chmod #{dest} to #{mode}", reason, session)
    end
  end

  defp maybe_chown(nil, _dest, _session), do: :ok

  defp maybe_chown(owner, dest, %Session{container_id: id, docker_options: opts} = session) do
    case Docker.exec_run_with_status(id, ["chown", "-R", owner, dest], opts) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, output: output}} ->
        error(
          :copy,
          "failed to chown #{dest} to #{owner}",
          %{status: code, body: output},
          session
        )

      {:error, reason} ->
        error(:copy, "failed to chown #{dest} to #{owner}", reason, session)
    end
  end

  defp container_dirname(path) do
    case Path.dirname(path) do
      "" -> "/"
      "." -> "/"
      dir -> dir
    end
  end

  defp wrap(:ok, _phase, _msg, _session), do: :ok

  defp wrap({:error, reason}, phase, msg, session),
    do: error(phase, msg, reason, session)

  defp error(phase, msg, reason, session),
    do: {:error, Error.docker_phase_error(phase, msg, reason, session)}
end
