defmodule Dockd.Spec.Interpolator do
  @moduledoc """
  `${VAR}` substitution for decoded `Dockd.Spec` documents.

  Walks a decoded JSON value (string, list, or map) and replaces every
  `${VAR}` and `${VAR:-default}` reference using the env map passed in
  by the caller. The env is a parameter — this module never reads
  `System.get_env/0` on its own — so it works the same way against the
  host environment, a fixture env in a test, or any merged map a future
  caller wants to compose.

  Knows nothing about `Dockd.Spec` shape. It operates on whatever
  decoded value `Dockd.Spec.Parser` produced.
  """

  alias Dockd.Error

  @var_pattern ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/

  @type env :: %{optional(binary()) => binary()}

  @doc """
  Substitutes every `${VAR}` reference in `value` using `env`.

  `value` can be a string, list, or map (nested arbitrarily). Returns
  `{:error, %Dockd.Error{phase: :validate}}` when a reference has no
  matching key in `env` and no `:-default` form.
  """
  @spec substitute(term(), env()) :: {:ok, term()} | {:error, Error.t()}
  def substitute(value, env) do
    walk(value, env, "$")
  end

  defp walk(value, env, path) when is_binary(value), do: walk_string(value, env, path)
  defp walk(value, env, path) when is_list(value), do: walk_list(value, env, path)
  defp walk(value, env, path) when is_map(value), do: walk_map(value, env, path)
  defp walk(value, _env, _path), do: {:ok, value}

  defp walk_string(str, env, path) do
    @var_pattern
    |> Regex.scan(str)
    |> Enum.reduce_while({:ok, str}, fn match, {:ok, acc} ->
      {full, var, has_default, default} = parse_match(match)

      case Map.fetch(env, var) do
        {:ok, val} ->
          {:cont, {:ok, String.replace(acc, full, val)}}

        :error when has_default ->
          {:cont, {:ok, String.replace(acc, full, default)}}

        :error ->
          {:halt,
           {:error,
            %Error{
              phase: :validate,
              message: "instance JSON references unset env var: #{var} (at #{path})"
            }}}
      end
    end)
  end

  # Three captures means the optional `:-default` group participated, so the
  # default is present by construction — no need to re-derive that from the
  # matched text. Two captures is the no-default form: `Regex.scan/2` drops the
  # trailing group entirely rather than yielding "".
  defp parse_match([full, var, default]), do: {full, var, true, default}

  defp parse_match([full, var]), do: {full, var, false, ""}

  defp walk_list(list, env, path) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, idx}, {:ok, acc} ->
      case walk(item, env, "#{path}[#{idx}]") do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  defp walk_map(map, env, path) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case walk(value, env, "#{path}.#{key}") do
        {:ok, val} -> {:cont, {:ok, Map.put(acc, key, val)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
