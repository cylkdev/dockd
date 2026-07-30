defmodule Dockd.HostTool do
  @moduledoc false

  # The single home for the two questions dockd repeatedly asks about a
  # caller-supplied host path, each of which used to have four or five separate
  # implementations at two or three different strictness levels:
  #
  #   - is this a usable directory to stage work under?
  #   - is this safe to delete recursively?
  #
  # Both are preflight checks on something the *caller* passed, run before any
  # side effect, so both report `:validate` — a bad `temp_root` is a bad
  # argument, not a failed copy. Callers used to re-tag them (`Dockd.Files` as
  # `:copy`) purely because that was the phase it tagged everything with; that
  # wrapper is gone and the phase is now decided in one place.
  #
  # `executable/3` and `env/2` used to live here too, for locating the `tar` that
  # `Dockd.Files` shelled out to. `:erl_tar` builds the archive in-process, so
  # there is no host executable left to check.

  @doc """
  Checks that `root` is a usable absolute host directory to stage work under.

  `label` is the argument's name (`"temp_root"`, `"staging_root"`) so the message
  names what the caller actually passed. Absoluteness is required because a
  relative path would resolve against the calling process's CWD.
  """
  @spec staging_root(term(), binary()) :: :ok | {:error, ErrorMessage.t()}
  def staging_root(root, label) when is_binary(root) and root !== "" do
    if Path.type(root) === :absolute,
      do: :ok,
      else:
        {:error,
         ErrorMessage.bad_request("#{label} must be an absolute path, got: #{inspect(root)}", %{
           phase: :validate
         })}
  end

  def staging_root(other, label),
    do:
      {:error,
       ErrorMessage.bad_request("a host #{label} is required, got: #{inspect(other)}", %{
         phase: :validate
       })}

  @doc """
  Checks that `root` is safe to delete recursively.

  Everything `staging_root/2` requires, plus a refusal to sweep `/`. This is the
  blast-radius check for `Dockd.delete_temp_files/1`, which is an `rm_rf`.
  """
  @spec sweepable_root(term(), binary()) :: :ok | {:error, ErrorMessage.t()}
  def sweepable_root(root, label) do
    with :ok <- staging_root(root, label) do
      if Path.absname(root) === "/",
        do: {:error, ErrorMessage.bad_request(~s(#{label} must not be "/"), %{phase: :validate})},
        else: :ok
    end
  end
end
