defmodule Dockd.Spec.Normalizer do
  @moduledoc """
  Convert a validated decoded `Dockd.Spec` map into keyword attrs
  suitable for `Dockd.Spec.from_attrs/1`.

  Responsibilities:

    - turn the JSON object's string keys into atom keys
    - validate and normalize the `"env"` list into `{name, opts}` tuples
    - validate the `"build"` map's keys and resolve relative
      `dockerfile`/`context` paths against `package_dir`

  Knows nothing about IO or `${VAR}` substitution. Operates on whatever
  decoded value `Dockd.Spec.Parser` (and optionally `Dockd.Spec.Interpolator`)
  produced.
  """

  alias Dockd.Error

  @build_keys ~w(dockerfile context args t extrahosts remote q nocache cachefrom pull rm
                 forcerm memory memswap cpushares cpusetcpus cpuperiod cpuquota
                 shmsize squash labels networkmode platform target outputs version)

  @build_path_keys [:dockerfile, :context]

  @env_entry_keys ~w(name value default optional)

  @doc """
  Normalizes the decoded JSON map into a `%{atom => term}` attrs map.

  `package_dir` is the directory that relative `build.dockerfile` and
  `build.context` paths should resolve against. Callers loading from a
  file pass `Path.dirname(path)`; callers working from an in-memory
  string typically pass `File.cwd!/0` or any chosen base directory.
  """
  @spec normalize(map(), Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def normalize(decoded, package_dir) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      atom = String.to_atom(key)

      case normalize_attr(atom, value, package_dir) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, atom, normalized)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp normalize_attr(:build, value, package_dir) when is_map(value) do
    case Map.keys(value) -- @build_keys do
      [] ->
        atom_keyed = for {k, v} <- value, into: %{}, do: {String.to_atom(k), v}
        {:ok, resolve_build_paths(atom_keyed, package_dir)}

      [key | _] ->
        {:error, %Error{phase: :validate, message: "unknown build key: #{inspect(key)}"}}
    end
  end

  defp normalize_attr(:build, _value, _package_dir),
    do:
      {:error, %Error{phase: :validate, message: "instance JSON key \"build\" must be an object"}}

  defp normalize_attr(:env, value, _package_dir) when is_list(value) do
    reduced =
      Enum.reduce_while(value, {:ok, []}, fn entry, {:ok, acc} ->
        case normalize_env_entry(entry) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, reversed} <- reduced, do: {:ok, Enum.reverse(reversed)}
  end

  defp normalize_attr(:env, _value, _package_dir),
    do: {:error, %Error{phase: :validate, message: "instance JSON key \"env\" must be a list"}}

  defp normalize_attr(_key, value, _package_dir), do: {:ok, value}

  defp normalize_env_entry(entry) when is_map(entry) do
    with :ok <- check_env_entry_keys(entry),
         {:ok, name} <- fetch_env_name(entry),
         :ok <- check_env_entry_types(entry, name),
         :ok <- check_env_entry_exclusions(entry, name) do
      {:ok, build_env_tuple(name, entry)}
    end
  end

  defp normalize_env_entry(other) do
    {:error,
     %Error{
       phase: :validate,
       message:
         ~s(:env entries must be JSON objects with at least a "name" key ) <>
           ~s|(e.g. {"name": "FOO", "optional": true}), got: #{inspect(other)}|
     }}
  end

  defp check_env_entry_keys(entry) do
    case Map.keys(entry) -- @env_entry_keys do
      [] ->
        :ok

      [bad | _] ->
        {:error, %Error{phase: :validate, message: ":env entry has unknown key: #{inspect(bad)}"}}
    end
  end

  defp fetch_env_name(entry) do
    case Map.get(entry, "name") do
      name when is_binary(name) and name !== "" ->
        {:ok, name}

      _ ->
        {:error,
         %Error{phase: :validate, message: ~s(:env entry requires a non-empty string "name")}}
    end
  end

  defp check_env_entry_types(entry, name) do
    cond do
      Map.has_key?(entry, "value") and not is_binary(Map.fetch!(entry, "value")) ->
        env_type_error(name, "value", "a string")

      Map.has_key?(entry, "default") and not is_binary(Map.fetch!(entry, "default")) ->
        env_type_error(name, "default", "a string")

      Map.has_key?(entry, "optional") and not is_boolean(Map.fetch!(entry, "optional")) ->
        env_type_error(name, "optional", "a boolean")

      true ->
        :ok
    end
  end

  defp env_type_error(name, key, expected),
    do:
      {:error,
       %Error{
         phase: :validate,
         message: ~s(:env entry #{inspect(name)} key "#{key}" must be #{expected})
       }}

  defp check_env_entry_exclusions(entry, name) do
    has_value = Map.has_key?(entry, "value")
    has_default = Map.has_key?(entry, "default")
    has_optional = Map.has_key?(entry, "optional")

    cond do
      has_value and has_default ->
        env_exclusion_error(name, ~s("value" cannot coexist with "default"))

      has_value and has_optional ->
        env_exclusion_error(name, ~s("value" cannot coexist with "optional"))

      has_default and has_optional ->
        env_exclusion_error(name, ~s("default" cannot coexist with "optional"))

      true ->
        :ok
    end
  end

  defp env_exclusion_error(name, msg),
    do: {:error, %Error{phase: :validate, message: ":env entry #{inspect(name)}: #{msg}"}}

  defp build_env_tuple(name, entry) do
    opts =
      []
      |> maybe_put_opt(:value, Map.get(entry, "value"))
      |> maybe_put_opt(:default, Map.get(entry, "default"))
      |> maybe_put_opt(:optional, Map.get(entry, "optional"))

    {name, opts}
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_build_paths(build, package_dir) do
    Enum.reduce(@build_path_keys, build, &resolve_build_path(&1, &2, package_dir))
  end

  defp resolve_build_path(key, acc, package_dir) do
    case Map.fetch(acc, key) do
      {:ok, value} when is_binary(value) -> put_resolved_path(acc, key, value, package_dir)
      _ -> acc
    end
  end

  defp put_resolved_path(acc, key, value, package_dir) do
    if Path.type(value) === :absolute do
      acc
    else
      Map.put(acc, key, Path.expand(value, package_dir))
    end
  end
end
