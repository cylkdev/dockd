defmodule Dockd.Spec do
  @moduledoc """
  Declarative request for a `Dockd.Instance`.

  A `Spec` describes the desired state of a container that dockd should produce:
  which image, which shell, which env, mounts, setup steps, and host files to
  copy. It is pure input — `Dockd.apply/6` consumes a `Spec` and
  produces a `Dockd.Instance` (a view of the resulting Docker container) plus a
  `Dockd.ApplyResult` (the one-shot provisioning outcome). The `Spec` itself is
  not persisted; after a container is created, Docker's own state (visible via
  `docker inspect`) is the source of truth.

  Caller-runtime concerns — the Docker daemon endpoint, host-disk policy, the
  host environment, and the host staging root — are *not* Spec fields. They are
  arguments to `Dockd.apply/6` and the other public functions, because they
  describe the calling process, not the instance.

  ## Construction

  Two entry points, one validation body:

    - `new/3` — from an image, an instance name, and a keyword list.
    - `from_map/1` — from a plain, atom-keyed map, which is how a *package*
      reaches dockd. A package is just data: you load it, dockd applies it.

  Both land on `validate/1`, so a map-sourced and an Elixir-native `Spec` are
  held to identical rules.

  `:image` and `:instance_name` are `@enforce_keys`, so a struct literal cannot
  omit them. It *can* still supply `nil`, which is why `validate/1` runs again as
  the first stage of `Dockd.Provisioner.run/6` — a hand-built `Spec` fails with a
  `:validate` error rather than crashing mid-pipeline.

  ## Naming

  `:instance_name` holds the **user-facing short name** — the value the caller
  passed, without the `dockd-` prefix. The prefix is applied at the Docker
  boundary by `prefix_name/1`, so there is exactly one representation in the
  struct and one place the container name is derived. `validate/1` rejects a
  name that already carries the prefix; otherwise `"foo"` and `"dockd-foo"`
  would name the same container.
  """

  @typedoc """
  One container environment entry.

  Two shapes, and only two:

    - `"NAME=value"` — a literal, passed through verbatim.
    - `"NAME"` — inherited from the `host_env` map passed to `Dockd.apply/6`;
      absent from it is a `:validate` error.
  """
  @type env_entry :: binary()

  @type t :: %__MODULE__{
          instance_name: binary(),
          description: binary() | nil,
          image: binary(),
          shell: binary() | nil,
          build: map() | nil,
          steps: [map()],
          copy: [map()],
          env: [env_entry()],
          mounts: [term()],
          labels: %{binary() => binary()}
        }

  @enforce_keys [:image, :instance_name]

  defstruct [
    :instance_name,
    :image,
    :description,
    :shell,
    :build,
    steps: [],
    copy: [],
    env: [],
    mounts: [],
    labels: %{}
  ]

  @container_name_prefix "dockd-"

  # Docker's own container-name grammar.
  @name_pattern ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/

  @spec_opts [
    :description,
    :shell,
    :steps,
    :build,
    :copy,
    :env,
    :mounts,
    :labels
  ]

  # Every key a spec map may carry. `:instance_name` is included here and not in
  # @spec_opts because `from_map/1` reads it from the map, while `new/3` takes it
  # as a positional argument.
  @map_keys [:instance_name, :image | @spec_opts]

  @doc """
  Returns the keyword keys accepted by `new/3`.

  `:instance_name` is not among them — it is a required positional argument.
  """
  @spec option_keys() :: [atom()]
  def option_keys, do: @spec_opts

  @doc """
  Builds a `Spec` from an image, an instance name, and a keyword list.

  The only constructor. Both required inputs are positional; everything else is
  optional and defaults to an empty collection. Returns `{:error, %ErrorMessage{}}`
  tagged `:validate` rather than raising — see `validate/1` for the rules.

      {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke", shell: "/bin/sh")
      spec.instance_name
      #=> "smoke"
  """
  @spec new(binary(), binary(), keyword()) :: {:ok, t()} | {:error, ErrorMessage.t()}
  def new(image, instance_name, opts \\ []) do
    spec = %__MODULE__{
      image: image,
      instance_name: instance_name,
      description: Keyword.get(opts, :description),
      shell: Keyword.get(opts, :shell),
      build: Keyword.get(opts, :build),
      steps: Keyword.get(opts, :steps, []),
      copy: Keyword.get(opts, :copy, []),
      env: Keyword.get(opts, :env, []),
      mounts: Keyword.get(opts, :mounts, []),
      labels: Keyword.get(opts, :labels, %{})
    }

    case validate(spec) do
      :ok -> {:ok, spec}
      {:error, _} = err -> err
    end
  end

  @doc """
  Builds a `Spec` from a plain map — the whole of dockd's "package" support.

  A package is a declarative map, **atom-keyed** — here and in every nested
  `:build`, `:steps`, `:copy` and `:mounts` entry:

      {:ok, spec} =
        Dockd.Spec.from_map(%{
          instance_name: "greeter",
          image: "busybox:1.37.0",
          shell: "/bin/sh",
          env: ["GREETING=hello"]
        })

  A string key is not accepted for any of them: it would be a second spelling of
  every field, and it is the caller — who chose the map's source — who knows how
  to convert one.

  Dockd deliberately does none of the work around that map:

    - **No file I/O.** To keep a package on disk, load it yourself. Nothing is
      resolved against a packages root, a working directory, or a home
      directory.
    - **No `${VAR}` substitution.** You build the map, so you interpolate it.
      A value in the map is the value that reaches Docker.
    - **No relative paths.** With no package directory to resolve against, a
      relative `:build` `dockerfile` or `context` would fall back to the calling
      process's CWD, so `validate/1` rejects one. Pass absolute paths.

  Unknown keys are rejected rather than ignored, so a typo fails at the boundary
  instead of silently doing nothing. Everything else — the required values, the
  name grammar, the build paths — is checked by the same `validate/1` that
  `new/3` uses.

  Returns `{:ok, spec}`, or `{:error, %ErrorMessage{code: :bad_request}}` with
  `details.phase` set to `:validate`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, ErrorMessage.t()}
  def from_map(map) when is_map(map) do
    with :ok <- validate_map_keys(map) do
      opts = Enum.map(@spec_opts, fn key -> {key, Map.get(map, key)} end)

      new(
        Map.get(map, :image),
        Map.get(map, :instance_name),
        Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
      )
    end
  end

  def from_map(other),
    do:
      {:error,
       ErrorMessage.bad_request(
         "Dockd.Spec.from_map/1 requires a map, got: #{inspect(other)}",
         %{phase: :validate}
       )}

  # `Map.keys/1` can hand back anything, so membership is tested with `in` and
  # rendered with `inspect/1`: a key that is not an atom at all must be
  # *reported*, not raise out of a function whose contract is a tagged error.
  defp validate_map_keys(map) do
    case Enum.reject(Map.keys(map), &(&1 in @map_keys)) do
      [] ->
        :ok

      unknown ->
        {:error,
         ErrorMessage.bad_request(
           "unknown spec key(s): #{Enum.map_join(Enum.sort_by(unknown, &inspect/1), ", ", &inspect/1)}. " <>
             "Valid keys: #{Enum.map_join(@map_keys, ", ", &inspect/1)}" <> atom_key_hint(unknown),
           %{phase: :validate}
         )}
    end
  end

  # A string-keyed map fails every key at once, which reads as a pile of typos
  # unless the actual cause is named.
  defp atom_key_hint(unknown) do
    if Enum.any?(unknown, &is_binary/1),
      do: ". Spec map keys must be atoms, not strings",
      else: ""
  end

  @doc """
  Checks every invariant a `Spec` must satisfy to reach the Docker daemon.

  The single validation point. `new/3` calls it, and `Dockd.Provisioner.run/6`
  calls it again on the way in so a hand-built struct literal cannot bypass it.

  Rejects, all as `%ErrorMessage{code: :bad_request}` with `details.phase` of
  `:validate`:

    - an `:image` that is not a non-empty binary
    - an `:instance_name` that is not a non-empty binary, does not match
      Docker's name grammar, or already starts with `dockd-`
    - a relative `:build` `dockerfile` or `context` path. There is no package
      directory to resolve one against, so a relative path would fall back to
      the calling process's CWD. Pass absolute paths.
  """
  @spec validate(t()) :: :ok | {:error, ErrorMessage.t()}
  def validate(%__MODULE__{} = spec) do
    with :ok <- validate_image(spec.image),
         :ok <- validate_instance_name(spec.instance_name),
         :ok <- validate_labels(spec.labels) do
      validate_build(spec.build)
    end
  end

  @doc """
  Prefixes an instance name with `dockd-` unless it already starts with that
  prefix.

  This is the one place a container name is derived from an instance name.
  Idempotent, so it is also safe on a caller-supplied reference in `Dockd.get/3`
  and friends, where the caller may reasonably paste either form.
  """
  @spec prefix_name(binary()) :: binary()
  def prefix_name(name) when is_binary(name) do
    if String.starts_with?(name, @container_name_prefix),
      do: name,
      else: @container_name_prefix <> name
  end

  @doc """
  Strips the `dockd-` prefix from a container name, returning the user-facing
  instance name.
  """
  @spec short_name(binary()) :: binary()
  def short_name(@container_name_prefix <> rest), do: rest
  def short_name(other) when is_binary(other), do: other

  # ---------------------------------------------------------------------------

  defp validate_image(image) when is_binary(image) and image !== "", do: :ok

  defp validate_image(other),
    do:
      {:error,
       ErrorMessage.bad_request(
         "Dockd.Spec requires a non-empty binary :image, got: #{inspect(other)}",
         %{phase: :validate}
       )}

  @spec validate_instance_name(term()) :: :ok | {:error, ErrorMessage.t()}
  defp validate_instance_name(name) when is_binary(name) and name !== "" do
    cond do
      String.starts_with?(name, @container_name_prefix) ->
        {:error,
         ErrorMessage.bad_request(
           ":instance_name must not include the #{@container_name_prefix} prefix " <>
             "(dockd adds it), got: #{inspect(name)}",
           %{phase: :validate}
         )}

      not Regex.match?(@name_pattern, name) ->
        {:error,
         ErrorMessage.bad_request(
           ":instance_name must match #{inspect(Regex.source(@name_pattern))}, " <>
             "got: #{inspect(name)}",
           %{phase: :validate}
         )}

      true ->
        :ok
    end
  end

  defp validate_instance_name(other),
    do:
      {:error,
       ErrorMessage.bad_request(
         "Dockd.Spec requires a non-empty binary :instance_name, got: #{inspect(other)}",
         %{phase: :validate}
       )}

  # Checked here so `Dockd.Provisioner` can merge the map straight into the
  # managed labels. It used to hedge with `user_labels || %{}` instead, which
  # meant a `nil` was silently acceptable everywhere except this one merge.
  defp validate_labels(labels) when is_map(labels), do: :ok

  defp validate_labels(other),
    do:
      {:error,
       ErrorMessage.bad_request(":labels must be a map, got: #{inspect(other)}", %{
         phase: :validate
       })}

  defp validate_build(nil), do: :ok

  defp validate_build(build) when is_map(build) do
    with :ok <- validate_absolute(build, :dockerfile) do
      validate_absolute(build, :context)
    end
  end

  defp validate_build(other),
    do:
      {:error,
       ErrorMessage.bad_request(":build must be a map or nil, got: #{inspect(other)}", %{
         phase: :validate
       })}

  defp validate_absolute(build, key) do
    case Map.get(build, key) do
      nil ->
        :ok

      path when is_binary(path) ->
        if Path.type(path) === :absolute,
          do: :ok,
          else:
            {:error,
             ErrorMessage.bad_request(
               ":build #{key} must be an absolute path, got: #{inspect(path)}",
               %{phase: :validate}
             )}

      other ->
        {:error,
         ErrorMessage.bad_request(
           ":build #{key} must be a string path, got: #{inspect(other)}",
           %{
             phase: :validate
           }
         )}
    end
  end
end
