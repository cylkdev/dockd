defmodule Dockd.FileCopy do
  @moduledoc """
  Copies files and directories from the host into a running container.

  Each spec is a `%{src, dest, mode?, owner?}` map. `src` is a host path (file or directory);
  `dest` is the absolute path the entry should appear at inside the container. The contents
  of `src` are tar-streamed to the container via `Docker.put_archive/4`, so the host files
  are never modified - unlike a bind mount, the container has its own copy.

  All specs in a single `copy_files/3` call are bundled into **one** tar archive and
  uploaded with a single `Docker.put_archive/4` call. The tar contains:

    - `entries/<index>` - the staged source for `specs[index]`
    - `manifest.tsv`    - tab-separated `entry\\tdest\\tmode\\towner` rows, one per spec
    - `run.sh`          - a POSIX shell script that reads `manifest.tsv` and moves each
                          entry to its final destination, applying `mode` / `owner` along
                          the way

  After upload, a single in-container `sh run.sh` exec does all the movement and optional
  `chmod` / `chown`, then cleans up the staging directory. Net Docker traffic per call is
  fixed at one `put_archive` plus two `exec` calls regardless of how many specs are passed.

  Errors are tagged with phase `:copy`. The caller (the provisioner) attaches a
  hydrated `Dockd.Instance` to the returned error so it can be cleaned up with
  `Dockd.destroy/1`.

  ## Responsibilities

    - Validate that each `src` exists on the host and that no `dest` contains a tab or
      newline before any side effects
    - Stage each `src` under `entries/<index>` in a single per-call host tempdir
    - Generate `manifest.tsv` and `run.sh` alongside the staged entries
    - Build one tar of the whole tempdir and `PUT` it into the container at a
      `/tmp/dockd-copy-<unique>` staging directory
    - Exec `sh /tmp/dockd-copy-<unique>/run.sh` inside the container to move each entry
      to its final location and apply optional `mode` / `owner`
    - Tear down the host tempdir whether the copy succeeds or fails

  ## Temp file housekeeping

  Per-call staging now lives under `<system_tmp>/dockd/dockd-copy-<unique>/`. On clean
  runs the `after` block tears it down. To sweep orphans left behind by hard kills or
  crashes, this module exposes `list_temp_files/0`, `delete_temp_files/0`, and
  `temp_files_info/0`. They operate on the entire `<system_tmp>/dockd/` tree, so they
  also cover `dockd-fetch-*` dirs created by `Dockd.Git`.
  """

  alias Dockd.Error

  @doc """
  Copies the given host files/directories into a running container in one batch.

  `specs` is a list of `%{src, dest, mode?, owner?}` maps. All entries are
  staged into a single per-call host tempdir, bundled into one tar, uploaded
  with a single `Docker.put_archive/4`, and moved into place by one
  in-container `run.sh` exec (applying any `:mode`/`:owner`). The host tempdir
  is always removed afterwards.

  Each `dest` must be free of tab and newline characters (they delimit the
  generated manifest), and each `src` must exist on the host. `docker_options`
  carries the Docker connection options. Returns `:ok` (also for an empty
  `specs` list, with no side effects) or `{:error, %Dockd.Error{}}` tagged
  `:copy`.
  """
  @spec copy_files([map()], binary(), keyword()) :: :ok | {:error, Error.t()}
  def copy_files([], _container_id, _docker_options), do: :ok

  def copy_files(specs, container_id, docker_options)
      when is_list(specs) and is_binary(container_id) and is_list(docker_options) do
    unique = "dockd-copy-#{System.unique_integer([:positive])}"
    host_tmp = Path.join(temp_root(), unique)
    container_staging = "/tmp/#{unique}"

    try do
      with :ok <- validate_paths(specs),
           :ok <- make_entries_dir(host_tmp),
           {:ok, rows} <- stage_all(specs, host_tmp),
           :ok <- write_manifest(rows, host_tmp),
           :ok <- write_runner(host_tmp, container_staging),
           {:ok, tar} <- tar_batch(host_tmp) do
        upload_and_run(container_id, container_staging, tar, docker_options)
      end
    after
      File.rm_rf(host_tmp)
    end
  end

  defp validate_paths(specs) do
    Enum.reduce_while(specs, :ok, fn %{dest: dest}, :ok ->
      cond do
        String.contains?(dest, "\t") ->
          {:halt, error("dest contains a tab character: #{inspect(dest)}", nil)}

        String.contains?(dest, "\n") ->
          {:halt, error("dest contains a newline character: #{inspect(dest)}", nil)}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp stage_all(specs, host_tmp) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, rows} ->
      case stage_one(spec, index, host_tmp) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      err -> err
    end
  end

  defp stage_one(%{src: src, dest: dest} = spec, index, host_tmp) do
    entry = "entries/#{index}"
    staged = Path.join(host_tmp, entry)
    expanded = Path.expand(src)

    with :ok <- stage_path(expanded, staged, src) do
      {:ok,
       %{
         entry: entry,
         dest: dest,
         mode: Map.get(spec, :mode),
         owner: Map.get(spec, :owner)
       }}
    end
  end

  defp stage_path(expanded, staged, src) do
    cond do
      File.regular?(expanded) ->
        case File.cp(expanded, staged) do
          :ok -> :ok
          {:error, reason} -> error("could not stage file #{src}", reason)
        end

      File.dir?(expanded) ->
        case File.cp_r(expanded, staged) do
          {:ok, _} -> :ok
          {:error, reason, path} -> error("could not stage dir #{path}", reason)
        end

      true ->
        {:error, %Error{phase: :copy, message: "copy source does not exist: #{src}"}}
    end
  end

  defp write_manifest(rows, host_tmp) do
    body =
      rows
      |> Enum.map(&manifest_line/1)
      |> Enum.join("\n")

    case File.write(Path.join(host_tmp, "manifest.tsv"), body <> "\n") do
      :ok -> :ok
      {:error, reason} -> error("could not write manifest", reason)
    end
  end

  defp manifest_line(%{entry: entry, dest: dest, mode: mode, owner: owner}) do
    Enum.join([entry, dest, mode || "", owner || ""], "\t")
  end

  defp write_runner(host_tmp, container_staging) do
    script = """
    #!/bin/sh
    set -e
    STAGING=#{shell_quote(container_staging)}
    cd "$STAGING"
    while IFS="\t" read -r entry dest mode owner; do
      if [ -z "$entry" ]; then continue; fi
      parent=$(dirname "$dest")
      mkdir -p "$parent"
      rm -rf "$dest"
      mv "$STAGING/$entry" "$dest"
      if [ -n "$mode" ];  then chmod -R "$mode"  "$dest"; fi
      if [ -n "$owner" ]; then chown -R "$owner" "$dest"; fi
    done < "$STAGING/manifest.tsv"
    rm -rf "$STAGING"
    """

    case File.write(Path.join(host_tmp, "run.sh"), script) do
      :ok -> :ok
      {:error, reason} -> error("could not write runner script", reason)
    end
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp tar_batch(host_tmp) do
    args =
      case :os.type() do
        {:unix, :darwin} ->
          [
            "--no-xattrs",
            "--no-acls",
            "--no-mac-metadata",
            "-C",
            host_tmp,
            "-cf",
            "-",
            "manifest.tsv",
            "run.sh",
            "entries"
          ]

        _ ->
          ["-C", host_tmp, "-cf", "-", "manifest.tsv", "run.sh", "entries"]
      end

    case System.cmd("tar", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> error("failed to tar batch", %{status: code, body: output})
    end
  end

  defp upload_and_run(container_id, container_staging, tar, docker_options) do
    with :ok <- mkdir_staging(container_id, container_staging, docker_options),
         :ok <- upload(container_id, container_staging, tar, docker_options) do
      run_script(container_id, container_staging, docker_options)
    end
  end

  defp mkdir_staging(container_id, container_staging, docker_options) do
    case Docker.exec_run_with_status(
           container_id,
           ["mkdir", "-p", container_staging],
           docker_options
         ) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, output: output}} ->
        error("failed to mkdir staging dir #{container_staging}", %{status: code, body: output})

      {:error, reason} ->
        error("failed to mkdir staging dir #{container_staging}", reason)
    end
  end

  defp upload(container_id, container_staging, tar, docker_options) do
    case Docker.put_archive(container_id, container_staging, tar, docker_options) do
      {:ok, _} -> :ok
      {:error, reason} -> error("failed to upload archive to #{container_staging}", reason)
    end
  end

  defp run_script(container_id, container_staging, docker_options) do
    script_path = container_staging <> "/run.sh"

    case Docker.exec_run_with_status(container_id, ["sh", script_path], docker_options) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, output: output}} ->
        error("failed to apply file copies", %{status: code, body: output})

      {:error, reason} ->
        error("failed to apply file copies", reason)
    end
  end

  defp make_entries_dir(host_tmp) do
    case File.mkdir_p(Path.join(host_tmp, "entries")) do
      :ok -> :ok
      {:error, reason} -> error("could not create staging dir", reason)
    end
  end

  defp error(msg, reason),
    do: {:error, Error.docker_phase_error(:copy, msg, reason, nil)}

  defp temp_root, do: Path.join(System.tmp_dir!(), "dockd")

  @doc """
  Lists absolute paths of every direct child of `<system_tmp>/dockd/`.

  Covers both `dockd-copy-*` staging dirs created by this module and `dockd-fetch-*`
  staging dirs created by `Dockd.Git`. Returns `[]` if the root does not yet exist.
  """
  @spec list_temp_files() :: [Path.t()]
  def list_temp_files do
    root = temp_root()

    case File.ls(root) do
      {:ok, entries} -> Enum.map(entries, &Path.join(root, &1))
      {:error, _} -> []
    end
  end

  @doc """
  Deletes every direct child of `<system_tmp>/dockd/`.

  Leaves the `<system_tmp>/dockd/` root itself in place. Returns `:ok` even if the
  root does not exist.
  """
  @spec delete_temp_files() :: :ok
  def delete_temp_files do
    Enum.each(list_temp_files(), &File.rm_rf!/1)
    :ok
  end

  @doc """
  Returns aggregate stats about the temp files in `<system_tmp>/dockd/`.

  Useful for deciding whether to call `delete_temp_files/0`. The `:total_bytes` value
  recursively sums regular-file sizes; `:oldest_at` / `:newest_at` are derived from
  each top-level entry's own mtime.
  """
  @spec temp_files_info() :: %{
          count: non_neg_integer(),
          total_bytes: non_neg_integer(),
          oldest_at: DateTime.t() | nil,
          newest_at: DateTime.t() | nil
        }
  def temp_files_info do
    list_temp_files()
    |> Enum.reduce(
      %{count: 0, total_bytes: 0, oldest_at: nil, newest_at: nil},
      fn path, acc ->
        mtime = entry_mtime(path)

        %{
          count: acc.count + 1,
          total_bytes: acc.total_bytes + du(path),
          oldest_at: min_time(acc.oldest_at, mtime),
          newest_at: max_time(acc.newest_at, mtime)
        }
      end
    )
  end

  defp du(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        size

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> Enum.reduce(entries, 0, &(du(Path.join(path, &1)) + &2))
          {:error, _} -> 0
        end

      _ ->
        0
    end
  end

  defp entry_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: posix}} -> DateTime.from_unix!(posix)
      {:error, _} -> nil
    end
  end

  defp min_time(nil, t), do: t
  defp min_time(t, nil), do: t
  defp min_time(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp max_time(nil, t), do: t
  defp max_time(t, nil), do: t
  defp max_time(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
end
