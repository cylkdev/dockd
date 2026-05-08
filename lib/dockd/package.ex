defmodule Dockd.Package do
  @moduledoc """
  A loader that turns a declarative JSON workspace recipe into `Dockd.prepare/2` arguments.

  A package is a JSON object whose keys mirror the options accepted by `Dockd.prepare/2`,
  plus a top-level `"image"` field that becomes the first positional argument. Packages can
  be **bundled** (shipped in `priv/packages/<name>.json`, addressed by name string) or
  **user-authored** (a path to any JSON file on disk). Either form is read by `load/1`.

  Every string value in the JSON is recursively scanned for `${VAR}` substitutions and
  replaced with the corresponding host environment variable's value. `${VAR:-default}`
  falls back to a literal default string when the variable is unset; `${VAR}` without a
  default produces a validation error that names the variable and its JSON path. Keys are
  never interpolated.

  The `"env"` field accepts only JSON objects — strings are not permitted in package
  JSON. Each object has a required `"name"` key plus at most one of:

    - `"value": "literal"` — set `name=literal` in the container; no host lookup.
    - `"default": "fallback"` — inherit from the host; fall back to the literal default
      when the host variable is unset.
    - `"optional": true` — inherit from the host when set; drop the entry when unset.

  A bare `{"name": "FOO"}` (no `value`, `default`, or `optional`) is a required
  passthrough — a `:validate` error is raised when `FOO` is unset on the host.

  Bare strings and tuples remain available through the Elixir API (`Dockd.prepare/2`
  with `env: [...]`); only the JSON loader enforces the object-only shape.

  Two file-management fields, `"repos"` and `"copy"`, materialize content inside the
  container before setup steps run. `"repos"` clones git repositories on the host and
  uploads the working tree (a shallow clone by default; opt into history with
  `"history": true`). `"copy"` ships host files or directories into the container as
  one-way snapshots. The third — `"mounts"` — accepts both legacy `"host:container[:ro]"`
  strings (mapped to Docker's `HostConfig.Binds`) and modern structured maps
  (`{"type": "tmpfs", "target": "/scratch"}`, mapped to `HostConfig.Mounts`). Use
  `"mounts"` when you want the host and container to share a directory live; use
  `"copy"` when you want isolation; use `"repos"` when the source of truth lives in git.

  ## Responsibilities

    - Resolve a package reference — string name (bundled) or path (file) — to a JSON
      file and read it
    - Recursively expand `${VAR}` substitutions from the host environment, with
      JSON-path-aware errors when a variable is unset
    - Validate the package shape: top-level must be a JSON object, keys must be in the
      allow-list mirroring `Dockd.prepare/2` options, `image` must be present and a string
    - Convert validated string keys to the atom keyword list shape `Dockd.prepare/2`
      requires, including the nested `build` map's allow-listed keys
    - Pass `setup_steps`-style entries through verbatim — `Dockd.prepare/2` already
      accepts string-keyed step maps, so no nested conversion happens here

  ## Example packages

  Authenticate the container by passing an API key from the host environment. Quick to
  set up; no shared login state across runs:

      {
        "image": "node:20-slim",
        "shell": "claude",
        "env": [{"name": "ANTHROPIC_API_KEY"}],
        "mounts": ["${PWD}:/workspace"],
        "steps": [
          {
            "label": "install claude-code",
            "cmd": ["npm", "install", "-g", "@anthropic-ai/claude-code"]
          }
        ]
      }

  Share the host's `~/.claude` directory so the OAuth login persists across container
  restarts. On macOS the credentials live in the system keychain, so log in once with
  `claude login` inside the container — the token is then written to
  `~/.claude/.credentials.json`, which sits on the host via the bind:

      {
        "image": "node:20-slim",
        "shell": "claude",
        "mounts": [
          "${PWD}:/workspace",
          "${HOME}/.claude:/root/.claude"
        ],
        "steps": [
          {
            "label": "install claude-code",
            "cmd": ["npm", "install", "-g", "@anthropic-ai/claude-code"]
          }
        ]
      }

  Clone a public git repo into the container and copy a single host config file to a
  fixed location with a tightened permission bit. The repo is cloned shallowly on the
  host (so host SSH/HTTPS credentials are reused), then tar-streamed into the container;
  the copied config is a one-way snapshot, so edits inside the container never reach
  the host:

      {
        "image": "python:3.12-slim",
        "shell": "/bin/bash",
        "repos": [
          {
            "url": "https://github.com/psf/requests",
            "ref": "main",
            "dest": "/workspace/requests"
          }
        ],
        "copy": [
          {
            "src": "${PWD}/config.yaml",
            "dest": "/etc/app/config.yaml",
            "mode": "0600"
          }
        ],
        "steps": [
          {"label": "install", "cmd": ["pip", "install", "-e", "/workspace/requests"]}
        ]
      }

  ## Examples

      # Bundled package shipped in priv/packages/claude_code_live_workspace.json.
      {:ok, {image, opts}} = Dockd.Package.load("claude_code_live_workspace")

      # User-authored package on disk.
      {:ok, {image, opts}} = Dockd.Package.load("./packages/my-stack.json")
      Dockd.prepare(image, opts)

  """

  alias Dockd.Error

  @top_level_keys Enum.map(Dockd.option_keys(), &Atom.to_string/1)

  @build_keys ~w(dockerfile context args t extrahosts remote q nocache cachefrom pull rm
                 forcerm memory memswap cpushares cpusetcpus cpuperiod cpuquota
                 shmsize squash labels networkmode platform target outputs version)

  @var_pattern ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/

  @doc """
  Loads a package and returns `{image, opts}` ready for `Dockd.prepare/2`.

  Always takes a string — never an atom — so package selection stays stateless and
  doesn't grow the BEAM atom table at runtime. The string is resolved to a JSON file
  using a single deterministic rule:

    - If `ref` ends with `.json` or contains `/`, it is a path to a JSON file on disk
      (loaded as-is, relative paths resolved against the current working directory).
    - Otherwise, `ref` is a **bundled name** — the basename of a file shipped in
      `priv/packages/<ref>.json`.

  Bundled names are tied 1:1 to filenames in `priv/packages/`, so listing the
  directory is the canonical catalog of presets.

  ## Parameters

    - `ref` - a string naming a bundled package (e.g. `"claude_code_live_workspace"`)
      or a path to a JSON file (e.g. `"./packages/my-stack.json"`).

  ## Returns

  `{:ok, {binary(), keyword()}}` on success — `image` is the first positional argument and
  `opts` is the keyword list of remaining options.

  `{:error, Dockd.Error.t()}` with `phase: :validate` for any failure: file read errors,
  invalid JSON, non-object top-level, unknown keys, missing `image`, missing env vars
  referenced by `${VAR}`.

  ## Examples

      # Bundled package shipped with dockd.
      {:ok, {image, opts}} = Dockd.Package.load("claude_code_live_workspace")

      # User-authored package on disk.
      {:ok, {image, opts}} = Dockd.Package.load("./packages/my-stack.json")
      Dockd.prepare(image, opts)

  """
  @spec load(binary()) :: {:ok, {binary(), keyword()}} | {:error, Error.t()}
  def load(ref) when is_binary(ref) do
    path = resolve(ref)
    package_dir = Path.dirname(path)

    with {:ok, body} <- read(path),
         {:ok, decoded} <- decode(body, path),
         :ok <- ensure_object(decoded),
         :ok <- check_unknown_keys(decoded),
         {:ok, interpolated} <- interpolate(decoded, "$"),
         {:ok, image, rest} <- pop_image(interpolated),
         {:ok, opts} <- to_keyword(rest, package_dir) do
      {:ok, {image, opts}}
    end
  end

  defp resolve(ref) do
    cond do
      String.ends_with?(ref, ".json") -> ref
      String.contains?(ref, "/") -> ref
      true -> Path.join([to_string(:code.priv_dir(:dockd)), "packages", "#{ref}.json"])
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         %Error{
           phase: :validate,
           message: "could not read package #{path}: #{:file.format_error(reason)}"
         }}
    end
  end

  defp decode(body, path) do
    case Jason.decode(body) do
      {:ok, value} ->
        {:ok, value}

      {:error, %Jason.DecodeError{} = err} ->
        {:error,
         %Error{
           phase: :validate,
           message: "invalid JSON in package #{path}: #{Exception.message(err)}"
         }}
    end
  end

  defp ensure_object(value) when is_map(value), do: :ok

  defp ensure_object(_),
    do: {:error, %Error{phase: :validate, message: "package must be a JSON object"}}

  defp check_unknown_keys(map) do
    allowed = ["image" | @top_level_keys]

    case Map.keys(map) -- allowed do
      [] ->
        :ok

      [key | _] ->
        {:error, %Error{phase: :validate, message: "unknown package key: #{inspect(key)}"}}
    end
  end

  defp interpolate(value, path) when is_binary(value), do: interpolate_string(value, path)
  defp interpolate(value, path) when is_list(value), do: interpolate_list(value, path)
  defp interpolate(value, path) when is_map(value), do: interpolate_map(value, path)
  defp interpolate(value, _path), do: {:ok, value}

  defp interpolate_string(str, path) do
    @var_pattern
    |> Regex.scan(str)
    |> Enum.reduce_while({:ok, str}, fn match, {:ok, acc} ->
      {full, var, has_default, default} = parse_match(match)

      case System.fetch_env(var) do
        {:ok, val} ->
          {:cont, {:ok, String.replace(acc, full, val)}}

        :error when has_default ->
          {:cont, {:ok, String.replace(acc, full, default)}}

        :error ->
          {:halt,
           {:error,
            %Error{
              phase: :validate,
              message: "package references unset env var: #{var} (at #{path})"
            }}}
      end
    end)
  end

  defp parse_match([full, var, default]),
    do: {full, var, String.contains?(full, ":-"), default}

  defp parse_match([full, var]), do: {full, var, false, ""}

  defp interpolate_list(list, path) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, idx}, {:ok, acc} ->
      case interpolate(item, "#{path}[#{idx}]") do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  defp interpolate_map(map, path) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case interpolate(value, "#{path}.#{key}") do
        {:ok, val} -> {:cont, {:ok, Map.put(acc, key, val)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp pop_image(map) do
    case Map.pop(map, "image") do
      {nil, _} ->
        {:error, %Error{phase: :validate, message: "package is missing required key: \"image\""}}

      {image, _rest} when not is_binary(image) ->
        {:error, %Error{phase: :validate, message: "package key \"image\" must be a string"}}

      {image, rest} ->
        {:ok, image, rest}
    end
  end

  defp to_keyword(map, package_dir) do
    # Keys have already been validated against @top_level_keys by check_unknown_keys/1,
    # so each one corresponds to an allowlisted Dockd option atom. String.to_atom/1 is
    # safe here (no untrusted input can reach it) and doesn't depend on the Dockd
    # module being loaded into the BEAM atom table at this point.
    Enum.reduce_while(map, {:ok, []}, fn {key, value}, {:ok, acc} ->
      atom = String.to_atom(key)

      case normalize_value(atom, value, package_dir) do
        {:ok, normalized} -> {:cont, {:ok, [{atom, normalized} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  # `:build` paths declared inside a package file are most usefully interpreted
  # relative to that file (the same convention Compose follows for the
  # build context) so a bundled or shared package travels with its Dockerfile.
  # Absolute paths are passed through unchanged.
  @build_path_keys [:dockerfile, :context]

  defp normalize_value(:build, value, package_dir) when is_map(value) do
    case Map.keys(value) -- @build_keys do
      [] ->
        # Keys are already validated against @build_keys, so String.to_atom/1 is safe.
        atom_keyed =
          for {k, v} <- value, into: %{} do
            {String.to_atom(k), v}
          end

        {:ok, resolve_build_paths(atom_keyed, package_dir)}

      [key | _] ->
        {:error,
         %Error{
           phase: :validate,
           message: "unknown build key: #{inspect(key)}"
         }}
    end
  end

  defp normalize_value(:build, _value, _package_dir) do
    {:error, %Error{phase: :validate, message: "package key \"build\" must be an object"}}
  end

  defp normalize_value(:env, value, _package_dir) when is_list(value) do
    result =
      Enum.reduce_while(value, {:ok, []}, fn entry, {:ok, acc} ->
        case normalize_env_entry(entry) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  defp normalize_value(:env, _value, _package_dir) do
    {:error, %Error{phase: :validate, message: "package key \"env\" must be a list"}}
  end

  defp normalize_value(_key, value, _package_dir), do: {:ok, value}

  @env_entry_keys ~w(name value default optional)

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
        {:error,
         %Error{phase: :validate, message: ":env entry has unknown key: #{inspect(bad)}"}}
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

  defp env_type_error(name, key, expected) do
    {:error,
     %Error{
       phase: :validate,
       message: ~s(:env entry #{inspect(name)} key "#{key}" must be #{expected})
     }}
  end

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

  defp env_exclusion_error(name, msg) do
    {:error, %Error{phase: :validate, message: ":env entry #{inspect(name)}: #{msg}"}}
  end

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
    Enum.reduce(@build_path_keys, build, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} when is_binary(value) ->
          if Path.type(value) == :absolute do
            acc
          else
            Map.put(acc, key, Path.expand(value, package_dir))
          end

        _ ->
          acc
      end
    end)
  end
end
