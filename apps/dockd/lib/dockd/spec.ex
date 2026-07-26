defmodule Dockd.Spec do
  @moduledoc """
  Declarative request for a `Dockd.Instance`.

  A `Spec` describes the desired state of a container that dockd should produce:
  which image, which shell, which env, mounts, setup steps, repos to clone, and
  host files to copy. It is pure input — `Dockd.apply/2` consumes a `Spec` and
  produces a `Dockd.Instance` (a view of the resulting Docker container) plus a
  `Dockd.ApplyResult` (the one-shot provisioning outcome). The `Spec` itself is
  not persisted; after a container is created, Docker's own state (visible via
  `docker inspect`) is the source of truth.

  Caller-runtime concerns — Docker daemon connection (`:socket`, `:host`,
  `:api_version`, `:platform`, `:networks`, `:network_mode`) and host-disk
  policy (`:disk_mount_enabled`) — are *not* Spec fields. They are per-call
  options on `Dockd.apply/2` and the other public functions, because they
  describe the calling process, not the instance.

  ## Construction

  Two entry points:

    - `from_opts/2` — build from an image string and a keyword list. The
      Elixir-native shape used by `Dockd.apply/2`.
    - `from_attrs/1` — build from an attrs map produced by composing
      `Dockd.Spec.Source`, `Dockd.Spec.Json`,
      `Dockd.Spec.Interpolator` (optional), and `Dockd.Spec.Normalizer`.
      The JSON-package shape; each step in that pipeline is its own
      module with a single responsibility.
  """

  @type env_entry :: binary() | {binary(), keyword()}

  @type t :: %__MODULE__{
          name: binary() | nil,
          description: binary() | nil,
          image: binary() | nil,
          shell: binary() | nil,
          build: map() | nil,
          steps: [map()],
          repos: [map()],
          copy: [map()],
          env: [env_entry()],
          mounts: [term()],
          labels: %{binary() => binary()}
        }

  defstruct [
    :name,
    :description,
    :image,
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

  @spec_opts [
    :name,
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

  @doc "Returns the keyword keys accepted by `from_opts/2`."
  @spec option_keys() :: [atom()]
  def option_keys, do: @spec_opts

  @doc """
  Builds a `Spec` from an image string and a keyword list of options.

  `:name` is required. The user-supplied value is prefixed with `dockd-`
  if it isn't already. Raises `ArgumentError` when `:name` is missing or
  not a non-empty binary.
  """
  @spec from_opts(binary(), keyword()) :: t()
  def from_opts(image, opts \\ []) when is_binary(image) and is_list(opts) do
    name =
      case Keyword.get(opts, :name) do
        provided when is_binary(provided) and provided !== "" ->
          prefix_name(provided)

        other ->
          raise ArgumentError,
                "Dockd.Spec requires a non-empty binary :name, got: #{inspect(other)}"
      end

    %__MODULE__{
      name: name,
      description: Keyword.get(opts, :description),
      image: image,
      shell: Keyword.get(opts, :shell),
      build: Keyword.get(opts, :build),
      steps: Keyword.get(opts, :steps, []),
      repos: Keyword.get(opts, :repos, []),
      copy: Keyword.get(opts, :copy, []),
      env: Keyword.get(opts, :env, []),
      mounts: Keyword.get(opts, :mounts, []),
      labels: Keyword.get(opts, :labels, %{})
    }
  end

  @doc """
  Builds a `Spec` from a normalized attrs map.

  Expects `attrs` to be the output of `Dockd.Spec.Normalizer.normalize/2`:
  atom-keyed, with `:image` present and `:env` already in `{name, opts}`
  tuple form. Composes `from_opts/2` by extracting the image and passing
  the rest as options.
  """
  @spec from_attrs(map()) :: t()
  def from_attrs(%{image: image} = attrs) when is_binary(image) do
    opts = attrs |> Map.delete(:image) |> Map.to_list()
    from_opts(image, opts)
  end

  @doc """
  Returns a deterministic content fingerprint for a spec.

  The fingerprint is a lowercase SHA-256 hex digest over the spec's declarative
  fields (image, shell, build, steps, repos, copies, env, mounts, labels, name,
  description). It is stable across processes and runs: map keys are sorted
  recursively before hashing, so two specs with the same content — regardless of
  key insertion order — produce the same digest.

  `Dockd.up/2` stamps this digest onto the container as a label at create time
  and recomputes it on a later `up` to decide whether the package spec has
  drifted (destroy + re-provision) or is unchanged (just start).
  """
  @spec fingerprint(t()) :: binary()
  def fingerprint(%__MODULE__{} = spec) do
    digest =
      spec
      |> Map.from_struct()
      |> canonical()
      |> :erlang.term_to_binary()

    :sha256
    |> :crypto.hash(digest)
    |> Base.encode16(case: :lower)
  end

  # Recursively rewrite maps into key-sorted lists so the encoding is
  # independent of map insertion order. Lists (including keyword lists and
  # env/mount tuples' option lists) are walked element-wise; everything else —
  # binaries, atoms, integers, tuples — is left as-is.
  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end)
    |> Enum.sort()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  @doc """
  Prefixes a instance name with `dockd-` unless it already starts with that
  prefix.
  """
  @spec prefix_name(binary()) :: binary()
  def prefix_name(name) when is_binary(name) do
    if String.starts_with?(name, @container_name_prefix),
      do: name,
      else: @container_name_prefix <> name
  end

  @doc """
  Strips the `dockd-` prefix from a container name, returning the
  user-facing instance name.
  """
  @spec short_name(binary()) :: binary()
  def short_name(@container_name_prefix <> rest), do: rest
  def short_name(other) when is_binary(other), do: other
end
