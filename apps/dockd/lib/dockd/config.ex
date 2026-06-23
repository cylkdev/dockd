defmodule Dockd.Config do
  @moduledoc """
  Configuration helper for the core Dockd application.

  Each accessor takes a per-call `opts` keyword list and resolves a core setting
  from three sources, in order of precedence:

    1. an explicit value in `opts` under the setting's key;
    2. the environment variable `DOCKD_<KEY>` (the key, upper-cased);
    3. the application environment (`config :dockd, <key>: ...`).

  The first non-`nil` source is then *resolved*: a binary or integer is taken
  as-is, a `{:system, "VAR"}` tuple is read from the environment, and any other
  shape resolves to `nil` and is replaced by the accessor's default.

  > #### Scalar values only {: .warning}
  >
  > Because resolution only accepts binaries, integers, and `{:system, _}`
  > tuples, any other shape supplied in application config resolves to `nil`
  > and falls back to the accessor default.

  ## Example

  ```elixir
  config :dockd,
    packages_path: "~/.dockd/packages",
    temp_dir: "/tmp/dockd"
  ```
  """

  @app :dockd

  @doc """
  Resolves the directory for dockd's temporary archive files
  (the `:temp_dir` setting).

  Defaults to `"dockd"` under the system temp directory
  (`System.tmp_dir!/0`) when unset.
  """
  @spec temp_dir(keyword()) :: binary() | integer()
  def temp_dir(opts) do
    opts
    |> get(:temp_dir)
    |> resolve()
    |> Kernel.||(Path.join(System.tmp_dir!(), "dockd"))
  end

  @doc """
  Resolves the directory where dockd package directories are stored.

  Defaults to `~/.dockd/packages` when unset. The value may be provided as
  `:packages_path` in opts, `DOCKD_PACKAGES_PATH`, or `config :dockd,
  packages_path: ...`.
  """
  @spec packages_path(keyword()) :: Path.t()
  def packages_path(opts) do
    opts
    |> get(:packages_path)
    |> resolve()
    |> Kernel.||(Path.join(System.user_home!(), ".dockd/packages"))
  end

  defp resolve(entries) do
    entries
    |> List.wrap()
    |> Enum.reduce_while(nil, fn
      value, _acc when is_binary(value) -> {:halt, value}
      value, _acc when is_integer(value) -> {:halt, value}
      {:system, key}, _acc -> {:halt, System.get_env(key)}
      _acc, _ -> {:cont, nil}
    end)
  end

  defp get(opts, key) do
    Keyword.get(opts, key) ||
      key |> key_to_env() |> System.get_env() ||
      Application.get_env(@app, key)
  end

  defp key_to_env(key) do
    "#{String.upcase(to_string(@app))}_#{String.upcase(to_string(key))}"
  end
end
