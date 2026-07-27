defmodule Dockd.Spec.Encoder do
  @moduledoc """
  Builds and pretty-prints a `package.json` document.

  The inverse direction of `Dockd.Spec.Parser` and `Dockd.Spec.Normalizer`:
  those read a package document off disk into a `Dockd.Spec`, this turns caller
  options into the document itself.

  Pure — nothing here touches the filesystem, so the shape of a generated
  package can be tested without writing anything. `Dockd.Packages.new/2` owns
  the IO.
  """

  alias Dockd.Error

  # Preferred key order, applied at every nesting level; anything unlisted
  # follows alphabetically. `url` and `src` precede `dest` (they never
  # co-occur) so a repo reads url/dest/ref and a copy reads src/dest/mode.
  # `name` sits late because by then it can only be an env entry's variable
  # name, and no other env key appears earlier.
  @key_order ~w(
    instance_name description image shell build env mounts repos copy steps labels
    step_name cmd workdir user url src dest ref depth history mode owner
    dockerfile context args name value default optional
  )

  @passthrough_keys [:description, :shell, :mounts, :repos, :copy, :steps, :labels]
  @env_opt_keys [:value, :default, :optional]
  @dockerfile_name "Dockerfile"
  @default_from "debian:trixie"

  # The instance name becomes part of the default image tag, so keep it to
  # characters a Docker reference accepts.
  @name_pattern ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/

  @doc """
  Builds the string-keyed JSON document from `opts`.

  Requires `:instance_name`. `:image` defaults to
  `"dockd-<instance_name>:latest"` — with the build always wired up, the image
  is the tag the build produces rather than something to pull.

  Only the keys present in `opts` are emitted.
  """
  @spec document(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def document(opts) when is_list(opts) do
    with {:ok, instance_name} <- fetch_instance_name(opts),
         {:ok, env} <- encode_env(Keyword.get(opts, :env, [])) do
      document =
        %{
          "instance_name" => instance_name,
          "image" => image(opts, instance_name),
          "build" => build(opts)
        }
        |> put_unless_empty("env", env)
        |> put_passthrough(opts)

      {:ok, document}
    end
  end

  @doc """
  Pretty-prints a document built by `document/1`.

  Elixir's built-in `JSON` encodes to a single line, which is no use for a file
  a human is expected to edit, so indentation is handled here. Scalars are
  still delegated to `JSON.encode!/1` — escaping is never hand-rolled.
  """
  @spec encode(map()) :: binary()
  def encode(document) when is_map(document), do: encode_value(document, 0) <> "\n"

  @doc """
  Returns the body of the generated `Dockerfile`.

  `:dockerfile` supplies a complete body verbatim; otherwise a minimal
  `FROM <from>` is generated, defaulting to `#{@default_from}`.
  """
  @spec dockerfile(keyword()) :: binary()
  def dockerfile(opts) when is_list(opts) do
    case Keyword.get(opts, :dockerfile) do
      body when is_binary(body) and body !== "" ->
        ensure_trailing_newline(body)

      _ ->
        "FROM #{Keyword.get(opts, :from, @default_from)}\n"
    end
  end

  @doc "The filename the generated build references."
  @spec dockerfile_name() :: binary()
  def dockerfile_name, do: @dockerfile_name

  # ---------------------------------------------------------------------------
  # Document assembly
  # ---------------------------------------------------------------------------

  defp fetch_instance_name(opts) do
    case Keyword.get(opts, :instance_name) do
      name when is_binary(name) and name !== "" ->
        if Regex.match?(@name_pattern, name) do
          {:ok, name}
        else
          {:error,
           validate_error(
             "instance name #{inspect(name)} must start with a letter or digit and " <>
               "contain only letters, digits, dots, dashes or underscores"
           )}
        end

      other ->
        {:error,
         validate_error("instance name must be a non-empty string, got: #{inspect(other)}")}
    end
  end

  defp image(opts, instance_name) do
    case Keyword.get(opts, :image) do
      image when is_binary(image) and image !== "" -> image
      _ -> "dockd-#{instance_name}:latest"
    end
  end

  defp build(opts) do
    extra = opts |> Keyword.get(:build, %{}) |> stringify()

    Map.merge(%{"dockerfile" => @dockerfile_name}, extra)
  end

  defp put_passthrough(document, opts) do
    Enum.reduce(@passthrough_keys, document, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> put_unless_empty(acc, Atom.to_string(key), stringify(value))
        :error -> acc
      end
    end)
  end

  defp put_unless_empty(map, _key, value) when value === [] or value === %{}, do: map
  defp put_unless_empty(map, _key, nil), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # env — the Elixir keyword shape differs from the JSON shape
  # ---------------------------------------------------------------------------

  defp encode_env(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case encode_env_entry(entry) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp encode_env(other),
    do: {:error, validate_error(":env must be a list, got: #{inspect(other)}")}

  defp encode_env_entry(entry) when is_binary(entry) do
    case String.split(entry, "=", parts: 2) do
      [name, value] ->
        with :ok <- check_env_name(name), do: {:ok, %{"name" => name, "value" => value}}

      [name] ->
        with :ok <- check_env_name(name), do: {:ok, %{"name" => name}}
    end
  end

  defp encode_env_entry({name, entry_opts}) when is_binary(name) and is_list(entry_opts) do
    with :ok <- check_env_name(name),
         :ok <- check_env_exclusive(name, entry_opts) do
      encoded =
        Enum.reduce(@env_opt_keys, %{"name" => name}, fn key, acc ->
          case Keyword.fetch(entry_opts, key) do
            {:ok, value} -> Map.put(acc, Atom.to_string(key), value)
            :error -> acc
          end
        end)

      {:ok, encoded}
    end
  end

  defp encode_env_entry(entry) when is_map(entry), do: {:ok, stringify(entry)}

  defp encode_env_entry(other),
    do:
      {:error,
       validate_error(
         ":env entries must be a string, a {name, opts} tuple or a map, got: #{inspect(other)}"
       )}

  defp check_env_name(name) when is_binary(name) and name !== "", do: :ok

  defp check_env_name(other),
    do: {:error, validate_error(":env entry requires a non-empty name, got: #{inspect(other)}")}

  # The normalizer rejects these combinations at load time; catching it here
  # gives a better message than failing when the package is eventually applied.
  defp check_env_exclusive(name, entry_opts) do
    case Enum.filter(@env_opt_keys, &Keyword.has_key?(entry_opts, &1)) do
      keys when length(keys) > 1 ->
        {:error,
         validate_error(
           ":env entry #{inspect(name)} may set at most one of :value, :default or " <>
             ":optional, got: #{inspect(keys)}"
         )}

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Pretty-printing
  # ---------------------------------------------------------------------------

  defp encode_value(map, _indent) when map === %{}, do: "{}"

  defp encode_value(map, indent) when is_map(map) do
    inner = indent + 1

    body =
      map
      |> sort_keys()
      |> Enum.map_join(",\n", fn {key, value} ->
        pad(inner) <> JSON.encode!(key) <> ": " <> encode_value(value, inner)
      end)

    "{\n" <> body <> "\n" <> pad(indent) <> "}"
  end

  defp encode_value([], _indent), do: "[]"

  defp encode_value(list, indent) when is_list(list) do
    if Enum.any?(list, &(is_map(&1) or is_list(&1))) do
      inner = indent + 1
      body = Enum.map_join(list, ",\n", fn value -> pad(inner) <> encode_value(value, inner) end)

      "[\n" <> body <> "\n" <> pad(indent) <> "]"
    else
      # A list of scalars reads better on one line: ["sh", "-c", "..."]
      "[" <> Enum.map_join(list, ", ", &JSON.encode!/1) <> "]"
    end
  end

  defp encode_value(scalar, _indent), do: JSON.encode!(scalar)

  defp sort_keys(map) do
    Enum.sort_by(map, fn {key, _value} ->
      case Enum.find_index(@key_order, &(&1 === key)) do
        nil -> {1, key}
        index -> {0, index}
      end
    end)
  end

  defp pad(indent), do: String.duplicate("  ", indent)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_key(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(key) when is_binary(key), do: key

  defp ensure_trailing_newline(body) do
    if String.ends_with?(body, "\n"), do: body, else: body <> "\n"
  end

  defp validate_error(message), do: %Error{phase: :validate, message: message}
end
