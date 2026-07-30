defmodule Dockd.Spec do
  @moduledoc """
  Declarative request for a `Dockd.Instance`.

  A `Spec` describes the desired state of a container that dockd should produce:
  which image, which shell, which env, mounts, setup steps, repos to clone, and
  host files to copy. It is pure input — `Dockd.apply/6` consumes a `Spec` and
  produces a `Dockd.Instance` (a view of the resulting Docker container) plus a
  `Dockd.ApplyResult` (the one-shot provisioning outcome). The `Spec` itself is
  not persisted; after a container is created, Docker's own state (visible via
  `docker inspect`) is the source of truth.

  Caller-runtime concerns — the Docker daemon endpoint, host-disk policy, the
  host environment, and the host staging root — are *not* Spec fields. They are
  arguments to `Dockd.apply/6` and the other public functions, because they
  describe the calling process, not the instance.

  ## Construction

  `new/3` is the only constructor. `from_attrs/1` adapts a normalized attrs map
  (the output of `Dockd.Spec.Parser` -> `Dockd.Spec.Interpolator` ->
  `Dockd.Spec.Normalizer`) onto it, so every `Spec` that dockd builds passes
  through the same validation in `validate/1`.

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

  alias Dockd.Error

  @type env_entry :: binary() | {binary(), keyword()}

  @type t :: %__MODULE__{
          instance_name: binary(),
          description: binary() | nil,
          image: binary(),
          shell: binary() | nil,
          build: map() | nil,
          steps: [map()],
          repos: [map()],
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
    repos: [],
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
    :repos,
    :copy,
    :env,
    :mounts,
    :labels
  ]

  @doc """
  Returns the keyword keys accepted by `new/3`.

  `:instance_name` is not among them — it is a required positional argument.
  """
  @spec option_keys() :: [atom()]
  def option_keys, do: @spec_opts

  @doc """
  Builds a `Spec` from an image, an instance name, and a keyword list.

  The only constructor. Both required inputs are positional; everything else is
  optional and defaults to an empty collection. Returns `{:error, %Dockd.Error{}}`
  tagged `:validate` rather than raising — see `validate/1` for the rules.

      {:ok, spec} = Dockd.Spec.new("busybox:1.37.0", "smoke", shell: "/bin/sh")
      spec.instance_name
      #=> "smoke"
  """
  @spec new(binary(), binary(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(image, instance_name, opts \\ []) do
    spec = %__MODULE__{
      image: image,
      instance_name: instance_name,
      description: Keyword.get(opts, :description),
      shell: Keyword.get(opts, :shell),
      build: Keyword.get(opts, :build),
      steps: Keyword.get(opts, :steps, []),
      repos: Keyword.get(opts, :repos, []),
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
  Builds a `Spec` from a normalized attrs map.

  Expects the output of `Dockd.Spec.Normalizer.normalize/2`: atom-keyed, with
  `:image` and `:instance_name` present and `:env` already in `{name, opts}`
  tuple form. Extracts the two required values and delegates to `new/3`, so
  package-sourced and Elixir-native specs share one validation body.
  """
  @spec from_attrs(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_attrs(attrs) do
    opts =
      attrs
      |> Map.drop([:image, :instance_name])
      |> Map.to_list()

    new(Map.get(attrs, :image), Map.get(attrs, :instance_name), opts)
  end

  @doc """
  Checks every invariant a `Spec` must satisfy to reach the Docker daemon.

  The single validation point. `new/3` calls it, and `Dockd.Provisioner.run/6`
  calls it again on the way in so a hand-built struct literal cannot bypass it.

  Rejects, all as `%Dockd.Error{phase: :validate}`:

    - an `:image` that is not a non-empty binary
    - an `:instance_name` that is not a non-empty binary, does not match
      Docker's name grammar, or already starts with `dockd-`
    - a relative `:build` `dockerfile` or `context` path. Package-sourced paths
      are absolutized against the package directory by
      `Dockd.Spec.Normalizer.normalize/2`; a relative path here would otherwise
      be resolved against the calling process's CWD.
  """
  @spec validate(t()) :: :ok | {:error, Error.t()}
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

  @doc false
  # Reads `key` from a map that may be atom- or string-keyed. Package documents
  # arrive string-keyed and only their *top-level* keys are atomized by
  # `Dockd.Spec.Normalizer`, so nested `:build` / step / repo / copy entries
  # genuinely show up either way. `Map.fetch/2` first rather than `||`, so a
  # legitimate `false` is not mistaken for an absent key.
  @spec fetch_either(map(), atom()) :: term()
  def fetch_either(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  # ---------------------------------------------------------------------------

  defp validate_image(image) when is_binary(image) and image !== "", do: :ok

  defp validate_image(other),
    do: error("Dockd.Spec requires a non-empty binary :image, got: #{inspect(other)}")

  @doc false
  # Public so `Dockd.Spec.Encoder` can gate a scaffolded package on the *same*
  # rules a loaded one is held to. It used to keep its own copy of the pattern
  # and its own message, and that copy omitted the `dockd-` prefix rejection —
  # so the scaffolder happily wrote a package that failed when applied.
  @spec validate_instance_name(term()) :: :ok | {:error, Error.t()}
  def validate_instance_name(name) when is_binary(name) and name !== "" do
    cond do
      String.starts_with?(name, @container_name_prefix) ->
        error(
          ":instance_name must not include the #{@container_name_prefix} prefix " <>
            "(dockd adds it), got: #{inspect(name)}"
        )

      not Regex.match?(@name_pattern, name) ->
        error(
          ":instance_name must match #{inspect(Regex.source(@name_pattern))}, " <>
            "got: #{inspect(name)}"
        )

      true ->
        :ok
    end
  end

  def validate_instance_name(other),
    do: error("Dockd.Spec requires a non-empty binary :instance_name, got: #{inspect(other)}")

  # Checked here so `Dockd.Provisioner` can merge the map straight into the
  # managed labels. It used to hedge with `user_labels || %{}` instead, which
  # meant a `nil` was silently acceptable everywhere except this one merge.
  defp validate_labels(labels) when is_map(labels), do: :ok

  defp validate_labels(other),
    do: error(":labels must be a map, got: #{inspect(other)}")

  defp validate_build(nil), do: :ok

  defp validate_build(build) when is_map(build) do
    with :ok <- validate_absolute(build, :dockerfile) do
      validate_absolute(build, :context)
    end
  end

  defp validate_build(other),
    do: error(":build must be a map or nil, got: #{inspect(other)}")

  defp validate_absolute(build, key) do
    case fetch_either(build, key) do
      nil ->
        :ok

      path when is_binary(path) ->
        if Path.type(path) === :absolute,
          do: :ok,
          else: error(":build #{key} must be an absolute path, got: #{inspect(path)}")

      other ->
        error(":build #{key} must be a string path, got: #{inspect(other)}")
    end
  end

  defp error(message), do: {:error, %Error{phase: :validate, message: message}}
end
