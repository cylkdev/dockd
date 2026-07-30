defmodule Dockd.FileCopy do
  @moduledoc """
  Copies files and directories from the host into a running container.

  Each spec is a `%{src, dest, mode?, owner?}` map. `src` is a host path (file or directory);
  `dest` is the absolute path the entry should appear at inside the container. The contents
  of `src` are tar-streamed to the container via `Docker.put_archive/4`, so the host files
  are never modified - unlike a bind mount, the container has its own copy.

  All specs in a single `copy_files/7` call are bundled into **one** tar archive and
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
  `Dockd.destroy/3`.

  ## Required inputs

  Nothing here is discovered from the environment. `temp_root` is the host directory
  to stage under, and `tar_path` / `tar_env` are the `tar` executable and the exact
  environment to run it in. `tar_path` is preflighted before any side effects, so a
  missing `tar` is a tagged `:copy` error rather than an `ErlangError` escaping
  `System.cmd/3`. Archive flags come from `:tar_extra_args`, not from `:os.type()` —
  see `tar_batch/4`.

  ## Responsibilities

    - Validate that each `src` is an absolute path that exists on the host, and that
      no `dest` contains a tab or newline, before any side effects
    - Stage each `src` under `entries/<index>` in a single per-call host tempdir
    - Generate `manifest.tsv` and `run.sh` alongside the staged entries
    - Build one tar of the whole tempdir and `PUT` it into the container at a
      `<container_staging_root>/dockd-copy-<unique>` staging directory
    - Exec `sh <staging>/run.sh` inside the container to move each entry to its final
      location and apply optional `mode` / `owner`
    - Tear down the host tempdir whether the copy succeeds or fails

  ## Temp file housekeeping

  Per-call staging lives under `<temp_root>/dockd-copy-<unique>/`. On clean runs the
  `after` block tears it down. To sweep orphans left behind by hard kills or crashes,
  this module exposes `list_temp_files/1` and `delete_temp_files/1`. They operate on
  whichever root the caller names, so they also cover `dockd-fetch-*` dirs created by
  `Dockd.Git` under the same root.
  """

  alias Dockd.Error
  alias Dockd.HostTool

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
  `{:error, %Dockd.Error{}}` tagged `:copy`.
  """
  @spec copy_files(
          [map()],
          binary(),
          Path.t(),
          Path.t(),
          %{optional(binary()) => binary()},
          keyword(),
          keyword()
        ) :: :ok | {:error, Error.t()}
  def copy_files(specs, container_id, temp_root, tar_path, tar_env, docker_options, opts \\ [])

  def copy_files([], _container_id, _temp_root, _tar_path, _tar_env, _docker_options, _opts),
    do: :ok

  def copy_files(specs, container_id, temp_root, tar_path, tar_env, docker_options, opts) do
    with :ok <- copy_check(HostTool.executable(tar_path, "tar", "copying host files")),
         :ok <- copy_check(HostTool.env(tar_env, "tar")),
         :ok <- copy_check(HostTool.staging_root(temp_root, "temp_root")),
         :ok <- validate_paths(specs) do
      unique = "dockd-copy-#{System.unique_integer([:positive])}"
      host_tmp = Path.join(temp_root, unique)

      container_staging =
        Path.join(Keyword.get(opts, :container_staging_root, "/tmp"), unique)

      extra_args = Keyword.get(opts, :tar_extra_args, [])

      try do
        with :ok <- make_entries_dir(host_tmp),
             {:ok, rows} <- stage_all(specs, host_tmp),
             :ok <- write_manifest(rows, host_tmp),
             :ok <- write_runner(host_tmp, container_staging),
             {:ok, tar} <- tar_batch(host_tmp, tar_path, tar_env, extra_args) do
          upload_and_run(container_id, container_staging, tar, docker_options)
        end
      after
        File.rm_rf(host_tmp)
      end
    end
  end

  # tar is preflighted rather than discovered: a missing tar used to raise
  # ErlangError out of System.cmd instead of returning a tagged error.
  defp copy_check(:ok), do: :ok
  defp copy_check({:error, message}), do: {:error, %Error{phase: :copy, message: message}}

  defp validate_paths(specs) do
    Enum.reduce_while(specs, :ok, fn %{dest: dest} = spec, :ok ->
      src = Map.get(spec, :src)

      cond do
        String.contains?(dest, "\t") ->
          {:halt, error("dest contains a tab character: #{inspect(dest)}", nil)}

        String.contains?(dest, "\n") ->
          {:halt, error("dest contains a newline character: #{inspect(dest)}", nil)}

        not is_binary(src) ->
          {:halt, error("copy src must be a string path, got: #{inspect(src)}", nil)}

        # Relative sources would resolve against the calling process's CWD.
        # Package-sourced paths are absolutized by Dockd.Spec.Normalizer.
        Path.type(src) !== :absolute ->
          {:halt, error("copy src must be an absolute path, got: #{inspect(src)}", nil)}

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
          :ok -> :ok
          {:error, reason} -> error("could not stage file #{src}", reason)
        end

      File.dir?(src) ->
        case File.cp_r(src, staged) do
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

  # Flags are not derived from :os.type(). The BSD-only trio
  # (--no-xattrs --no-acls --no-mac-metadata) is wrong for a GNU tar that happens
  # to be installed on macOS, so the caller who chose `tar_path` also chooses its
  # flags via `:tar_extra_args`.
  defp tar_batch(host_tmp, tar_path, tar_env, extra_args) do
    args = extra_args ++ ["-C", host_tmp, "-cf", "-", "manifest.tsv", "run.sh", "entries"]

    cmd_opts = [
      stderr_to_stdout: true,
      cd: host_tmp,
      env: Enum.map(tar_env, fn {name, value} -> {to_string(name), to_string(value)} end)
    ]

    case System.cmd(tar_path, args, cmd_opts) do
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

  @doc """
  Lists absolute paths of every direct child of `temp_root`.

  Covers both `dockd-copy-*` staging dirs created by this module and `dockd-fetch-*`
  staging dirs created by `Dockd.Git`. Returns `[]` if the root does not yet exist.
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
  @spec delete_temp_files(Path.t()) :: :ok | {:error, Error.t()}
  def delete_temp_files(temp_root) do
    with :ok <- safe_to_sweep(temp_root) do
      temp_root
      |> list_temp_files()
      |> Enum.each(&File.rm_rf!/1)
    end
  end

  defp safe_to_sweep(root) do
    case HostTool.sweepable_root(root, "temp_root") do
      :ok -> :ok
      {:error, message} -> {:error, %Error{phase: :destroy, message: message}}
    end
  end
end
