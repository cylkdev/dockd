defmodule DockdCLI.Options do
  @moduledoc """
  Resolves runtime Docker connection options. Precedence: explicit CLI
  flag > environment variable > absent. Mirrors the Docker CLI's own
  `--host` / `DOCKER_HOST` convention.
  """

  @spec resolve(map(), map()) :: keyword()
  def resolve(flags, env) do
    []
    |> put(:socket, pick(flags[:socket], env["DOCKER_SOCKET"]))
    |> put(:host, pick(flags[:host], env["DOCKER_HOST"]))
  end

  defp pick(flag, _env) when is_binary(flag) and flag != "", do: flag
  defp pick(_flag, env) when is_binary(env) and env != "", do: env
  defp pick(_flag, _env), do: nil

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)
end
