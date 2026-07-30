defmodule Dockd.Spec.Parser do
  @moduledoc """
  JSON decoding and structural validation for `Dockd.Spec` documents.

  Takes a JSON string and returns a validated decoded map. The map is
  guaranteed to:

    - be a JSON object
    - contain only keys recognized by `Dockd.Spec`
    - have a `"description"` value that is a string when present

  Checks *shape*, not semantic required-ness. Whether `"image"` and
  `"instance_name"` are present and usable is `Dockd.Spec.validate/1`'s job, so
  that rule lives in exactly one place and reports one way for every
  construction path.

  Does no `${VAR}` substitution and no attribute normalization — those belong to
  `Dockd.Spec.Interpolator` and `Dockd.Spec.Normalizer`.
  """

  alias Dockd.Error

  @allowed_keys ~w(instance_name description image shell steps build repos copy env mounts labels)

  @doc """
  Reads the JSON document at `path` and parses it.

  Read errors (missing file, permission denied) and parse errors share the same
  `:validate`-phase `Dockd.Error` shape, so callers handle one failure type.
  """
  @spec parse_file(Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def parse_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        parse(body)

      {:error, reason} ->
        {:error,
         %Error{
           phase: :validate,
           message: "could not read file #{path}: #{:file.format_error(reason)}"
         }}
    end
  end

  @doc """
  Decodes `json_string` and runs structural validation.

  Returns `{:error, %Dockd.Error{phase: :validate}}` on any parse,
  shape, key, or required-field error.
  """
  @spec parse(binary()) :: {:ok, map()} | {:error, Error.t()}
  def parse(json_string) when is_binary(json_string) do
    with {:ok, value} <- decode_json(json_string),
         :ok <- ensure_object(value),
         :ok <- check_unknown_keys(value) do
      check_description(value)
      |> case do
        :ok -> {:ok, value}
        err -> err
      end
    end
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error,
         %Error{
           phase: :validate,
           message: "invalid JSON: #{inspect(reason)}"
         }}
    end
  end

  defp ensure_object(value) when is_map(value), do: :ok

  defp ensure_object(_),
    do: {:error, %Error{phase: :validate, message: "package JSON must be an object"}}

  defp check_unknown_keys(map) do
    case Map.keys(map) -- @allowed_keys do
      [] ->
        :ok

      [key | _] ->
        {:error, %Error{phase: :validate, message: unknown_key_message(key)}}
    end
  end

  # The top-level `"name"` was renamed to `"instance_name"` — it names the
  # container, not the package, and `"name"` still means an env entry's variable
  # name elsewhere in the document. Point at the replacement rather than
  # reporting a bare unknown key.
  defp unknown_key_message("name"),
    do: ~s(package JSON key "name" was renamed to "instance_name")

  defp unknown_key_message(key), do: "unknown package key: #{inspect(key)}"


  defp check_description(map) do
    case Map.get(map, "description") do
      nil ->
        :ok

      value when is_binary(value) ->
        :ok

      _ ->
        {:error,
         %Error{phase: :validate, message: ~s(package JSON key "description" must be a string)}}
    end
  end

end
