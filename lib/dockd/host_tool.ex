defmodule Dockd.HostTool do
  @moduledoc false

  # The single home for the three questions dockd repeatedly asks about a
  # caller-supplied host path, each of which used to have four or five separate
  # implementations at two or three different strictness levels:
  #
  #   - does this name an executable we can run?
  #   - is this a usable directory to stage work under?
  #   - is this safe to delete recursively?
  #
  # Every function returns a bare message rather than a `%Dockd.Error{}`, so the
  # caller supplies its own phase tag. That also lets `Dockd.Ssh` and
  # `Dockd.Ssh.DockerDialStdio`, whose contract is `{:error, binary()}`, share
  # these rules instead of reimplementing them.

  @doc """
  Checks that `path` names a runnable file.

  `tool` is the executable's name ("git", "tar") and doubles as the option-key
  prefix in the error; `because` names what needed it.
  """
  @spec executable(term(), binary(), binary()) :: :ok | {:error, binary()}
  def executable(path, tool, _because) when is_binary(path) and path !== "" do
    if File.regular?(path),
      do: :ok,
      else: {:error, "#{tool}_path does not name a file: #{path}"}
  end

  def executable(other, tool, because) do
    {:error,
     "#{because} needs #{tool}. Pass #{tool}_path with the absolute path to the #{tool} " <>
       "executable, got: #{inspect(other)}"}
  end

  @doc """
  Checks that `env` is a `%{name => value}` map.

  `%{}` is valid and means "run with no inherited environment at all" — the
  point of requiring it explicitly.
  """
  @spec env(term(), binary()) :: :ok | {:error, binary()}
  def env(env, _tool) when is_map(env), do: :ok

  def env(other, tool),
    do: {:error, "#{tool}_env must be a map of name => value, got: #{inspect(other)}"}

  @doc """
  Checks that `root` is a usable absolute host directory to stage work under.

  `label` is the argument's name (`"temp_root"`, `"staging_root"`) so the message
  names what the caller actually passed. Absoluteness is required because a
  relative path would resolve against the calling process's CWD.
  """
  @spec staging_root(term(), binary()) :: :ok | {:error, binary()}
  def staging_root(root, label) when is_binary(root) and root !== "" do
    if Path.type(root) === :absolute,
      do: :ok,
      else: {:error, "#{label} must be an absolute path, got: #{inspect(root)}"}
  end

  def staging_root(other, label),
    do: {:error, "a host #{label} is required, got: #{inspect(other)}"}

  @doc """
  Checks that `root` is safe to delete recursively.

  Everything `staging_root/2` requires, plus a refusal to sweep `/`. This is the
  blast-radius check for `Dockd.delete_temp_files/1`, which is an `rm_rf`.
  """
  @spec sweepable_root(term(), binary()) :: :ok | {:error, binary()}
  def sweepable_root(root, label) do
    with :ok <- staging_root(root, label) do
      if Path.absname(root) === "/",
        do: {:error, ~s(#{label} must not be "/")},
        else: :ok
    end
  end
end
