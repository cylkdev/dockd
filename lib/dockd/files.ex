defmodule Dockd.Files do
  @moduledoc """
  Copies files and directories from the host into a running container.

  Each spec is a `%{src, dest, mode?, owner?}` map. `src` is a host path (file or directory);
  `dest` is the absolute path the entry should appear at inside the container. The contents
  of `src` are tar-streamed to the container via `Docker.put_archive/4`, so the host files
  are never modified - unlike a bind mount, the container has its own copy.

  All specs in a single `copy_files/5` call are bundled into **one** tar archive and
  uploaded with a single `Docker.put_archive/4` call. The tar contains:

    - `entries/<index>` - the staged source for `specs[index]`
    - `manifest.tsv`    - tab-separated `entry\\tdest\\tmode\\towner` rows, one per spec
    - `run.sh`          - a POSIX shell script that reads `manifest.tsv` and moves each
                          entry to its final destination, applying `mode` / `owner` along
                          the way

  After upload, a single in-container `sh run.sh` exec does all the movement and optional
  `chmod` / `chown`, then cleans up the staging directory. Net Docker traffic per call is
  fixed at one `put_archive` plus two `exec` calls regardless of how many specs are passed.

  Failures during the copy itself carry `details.phase` of `:copy`; the preflight
  check on `temp_root` carries `:validate`, because that is a bad argument rather
  than a failed copy. The caller (the provisioner) attaches a hydrated
  `Dockd.Instance` to `details` so it can be cleaned up with `Dockd.destroy/3`.

  ## Required inputs

  Nothing here is discovered from the environment, and there is only one input to
  supply: `temp_root`, the host directory to stage under.

  ## The archive is built in-process

  `build_archive/1` uses OTP's `:erl_tar`, so **dockd runs no external program**.
  There is no `tar` executable to locate, no environment to hand it, and no
  archive flags to choose: `:erl_tar` writes no xattrs, ACLs or macOS metadata to
  begin with, which is the entire reason the retired `:tar_extra_args` option
  existed. It also preserves what a copy needs — recursive directories, empty
  directories, symlinks, permission bits, and names past the 100-byte ustar limit
  — and reports an unreadable source as `{:error, {path, reason}}` rather than as
  a warning on a stderr stream that would otherwise have to be kept away from the
  archive bytes.

  ## Responsibilities

    - Validate that each `src` is an absolute path that exists on the host, and that
      no `dest` contains a tab or newline, before any side effects
    - Stage each `src` under `entries/<index>` in a single per-call host tempdir
    - Generate `manifest.tsv` and `run.sh` alongside the staged entries
    - Build one tar of the staged entries with `:erl_tar` and `PUT` it into the
      container at a `<container_staging_root>/dockd-copy-<unique>` staging directory
    - Exec `sh <staging>/run.sh` inside the container to move each entry to its final
      location and apply optional `mode` / `owner`
    - Tear down the host tempdir whether the copy succeeds or fails

  ## Temp file housekeeping

  Per-call staging lives under `<temp_root>/dockd-copy-<unique>/`. On clean runs the
  `after` block tears it down. To sweep orphans left behind by hard kills or crashes,
  this module exposes `list_temp_files/1` and `delete_temp_files/1`. They operate on
  whichever root the caller names.
  """

  alias Dockd.HostTool

  # Written inside the staging dir, and never added to itself: `build_archive/1`
  # adds the three entries it wants by name rather than globbing the directory.
  @archive_name "archive.tar"

  @doc """
  Copies the given host files/directories into a running container in one batch.

  `specs` is a list of `%{src, dest, mode?, owner?}` maps. All entries are
  staged into a single per-call host tempdir, bundled into one tar, uploaded
  with a single `Docker.put_archive/4`, and moved into place by one
  in-container `run.sh` exec (applying any `:mode`/`:owner`). The host tempdir
  is always removed afterwards.

  Each `dest` must be free of tab and newline characters (they delimit the
  generated manifest), and each `src` must be an **absolute** path that exists on
  the host — a relative one would resolve against the calling process's working
  directory. `docker_options` carries the Docker connection options. Returns `:ok`
  (also for an empty `specs` list, with no side effects) or
  `{:error, %ErrorMessage{}}`.
  """
  @spec copy_files([map()], binary(), Path.t(), keyword(), keyword()) ::
          :ok | {:error, ErrorMessage.t()}
  def copy_files(specs, container_id, temp_root, docker_options, opts \\ [])

  def copy_files([], _container_id, _temp_root, _docker_options, _opts), do: :ok

  def copy_files(specs, container_id, temp_root, docker_options, opts) do
    with :ok <- HostTool.staging_root(temp_root, "temp_root"),
         :ok <- validate_paths(specs) do
      unique = "dockd-copy-#{System.unique_integer([:positive])}"
      host_tmp = Path.join(temp_root, unique)

      container_staging =
        Path.join(Keyword.get(opts, :container_staging_root, "/tmp"), unique)

      try do
        with :ok <- make_entries_dir(host_tmp),
             {:ok, rows} <- stage_all(specs, host_tmp),
             :ok <- write_manifest(rows, host_tmp),
             :ok <- write_runner(host_tmp, container_staging),
             {:ok, tar} <- build_archive(host_tmp) do
          upload_and_run(container_id, container_staging, tar, docker_options)
        end
      after
        File.rm_rf(host_tmp)
      end
    end
  end

  defp validate_paths(specs) do
    Enum.reduce_while(specs, :ok, fn %{dest: dest} = spec, :ok ->
      src = Map.get(spec, :src)

      cond do
        String.contains?(dest, "\t") ->
          {:halt,
           {:error,
            ErrorMessage.unprocessable_entity(
              "dest contains a tab character: #{inspect(dest)}",
              %{phase: :copy}
            )}}

        String.contains?(dest, "\n") ->
          {:halt,
           {:error,
            ErrorMessage.unprocessable_entity(
              "dest contains a newline character: #{inspect(dest)}",
              %{phase: :copy}
            )}}

        not is_binary(src) ->
          {:halt,
           {:error,
            ErrorMessage.unprocessable_entity(
              "copy src must be a string path, got: #{inspect(src)}",
              %{phase: :copy}
            )}}

        # Relative sources would resolve against the calling process's CWD.
        Path.type(src) !== :absolute ->
          {:halt,
           {:error,
            ErrorMessage.unprocessable_entity(
              "copy src must be an absolute path, got: #{inspect(src)}",
              %{phase: :copy}
            )}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp stage_all(specs, host_tmp) do
    reduced =
      specs
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, rows} ->
        case stage_one(spec, index, host_tmp) do
          {:ok, row} -> {:cont, {:ok, [row | rows]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, rows} <- reduced, do: {:ok, Enum.reverse(rows)}
  end

  defp stage_one(%{src: src, dest: dest} = spec, index, host_tmp) do
    entry = "entries/#{index}"
    staged = Path.join(host_tmp, entry)

    # `src` is already absolute — validate_paths/1 rejects anything else, so there
    # is no Path.expand and no dependency on the caller's CWD.
    with :ok <- stage_path(src, staged) do
      {:ok,
       %{
         entry: entry,
         dest: dest,
         mode: Map.get(spec, :mode),
         owner: Map.get(spec, :owner)
       }}
    end
  end

  defp stage_path(src, staged) do
    cond do
      File.regular?(src) ->
        case File.cp(src, staged) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error,
             ErrorMessage.unprocessable_entity("could not stage file #{src}", %{
               phase: :copy,
               reason: reason
             })}
        end

      File.dir?(src) ->
        case File.cp_r(src, staged) do
          {:ok, _} ->
            :ok

          {:error, reason, path} ->
            {:error,
             ErrorMessage.unprocessable_entity("could not stage dir #{path}", %{
               phase: :copy,
               reason: reason
             })}
        end

      true ->
        {:error,
         ErrorMessage.unprocessable_entity("copy source does not exist: #{src}", %{phase: :copy})}
    end
  end

  defp write_manifest(rows, host_tmp) do
    body =
      rows
      |> Enum.map(&manifest_line/1)
      |> Enum.join("\n")

    case File.write(Path.join(host_tmp, "manifest.tsv"), body <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         ErrorMessage.unprocessable_entity("could not write manifest", %{
           phase: :copy,
           reason: reason
         })}
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
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         ErrorMessage.unprocessable_entity("could not write runner script", %{
           phase: :copy,
           reason: reason
         })}
    end
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  # `:erl_tar`, not an external `tar`: nothing to locate on PATH, no environment
  # to hand a child process, and no archive flags to pick. The three members are
  # added by name (relative to `host_tmp`) so the archive being written inside
  # `host_tmp` is never swept into itself.
  defp build_archive(host_tmp) do
    archive = Path.join(host_tmp, @archive_name)

    case :erl_tar.open(to_charlist(archive), [:write]) do
      {:ok, tar} ->
        # Closed before the read, not after it: the archive is not complete on
        # disk until `close/1` has written the trailer.
        added =
          try do
            add_members(tar, host_tmp)
          after
            :erl_tar.close(tar)
          end

        with :ok <- added, do: read_archive(archive)

      {:error, reason} ->
        {:error,
         ErrorMessage.unprocessable_entity("could not open archive", %{
           phase: :copy,
           reason: reason
         })}
    end
  end

  defp add_members(tar, host_tmp) do
    Enum.reduce_while(["manifest.tsv", "run.sh", "entries"], :ok, fn member, :ok ->
      path = to_charlist(Path.join(host_tmp, member))

      case :erl_tar.add(tar, path, to_charlist(member), []) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            ErrorMessage.unprocessable_entity("could not add #{member} to the archive", %{
              phase: :copy,
              reason: reason
            })}}
      end
    end)
  end

  # `:erl_tar` has no in-memory sink, so the archive is written alongside the
  # staged entries and read back. It lives in the tempdir the `after` block
  # already removes, so this adds no cleanup path of its own.
  defp read_archive(archive) do
    case File.read(archive) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, reason} ->
        {:error,
         ErrorMessage.unprocessable_entity("could not read archive", %{
           phase: :copy,
           reason: reason
         })}
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
        {:error,
         ErrorMessage.unprocessable_entity("failed to mkdir staging dir #{container_staging}", %{
           phase: :copy,
           reason: %{status: code, body: output}
         })}

      {:error, reason} ->
        {:error,
         ErrorMessage.unprocessable_entity("failed to mkdir staging dir #{container_staging}", %{
           phase: :copy,
           reason: reason
         })}
    end
  end

  defp upload(container_id, container_staging, tar, docker_options) do
    case Docker.put_archive(container_id, container_staging, tar, docker_options) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error,
         ErrorMessage.unprocessable_entity("failed to upload archive to #{container_staging}", %{
           phase: :copy,
           reason: reason
         })}
    end
  end

  defp run_script(container_id, container_staging, docker_options) do
    script_path = container_staging <> "/run.sh"

    case Docker.exec_run_with_status(container_id, ["sh", script_path], docker_options) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, output: output}} ->
        {:error,
         ErrorMessage.unprocessable_entity("failed to apply file copies", %{
           phase: :copy,
           reason: %{status: code, body: output}
         })}

      {:error, reason} ->
        {:error,
         ErrorMessage.unprocessable_entity("failed to apply file copies", %{
           phase: :copy,
           reason: reason
         })}
    end
  end

  defp make_entries_dir(host_tmp) do
    case File.mkdir_p(Path.join(host_tmp, "entries")) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         ErrorMessage.unprocessable_entity("could not create staging dir", %{
           phase: :copy,
           reason: reason
         })}
    end
  end

  @doc """
  Lists absolute paths of every direct child of `temp_root`.

  Covers the `dockd-copy-*` staging dirs created by this module. Returns `[]` if
  the root does not yet exist.
  """
  @spec list_temp_files(Path.t()) :: [Path.t()]
  def list_temp_files(temp_root) when is_binary(temp_root) do
    case File.ls(temp_root) do
      {:ok, entries} -> Enum.map(entries, &Path.join(temp_root, &1))
      {:error, _} -> []
    end
  end

  @doc """
  Deletes every direct child of `temp_root`, leaving the root itself in place.

  Returns `:ok` even if the root does not exist. `temp_root` must be an absolute
  path other than `"/"` — this function recursively deletes, so it refuses to
  accept a root that would sweep the filesystem.
  """
  @spec delete_temp_files(Path.t()) :: :ok | {:error, ErrorMessage.t()}
  def delete_temp_files(temp_root) do
    with :ok <- HostTool.sweepable_root(temp_root, "temp_root") do
      temp_root
      |> list_temp_files()
      |> Enum.each(&File.rm_rf!/1)
    end
  end
end
