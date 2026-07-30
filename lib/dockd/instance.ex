defmodule Dockd.Instance do
  @moduledoc """
  A view of a Docker container that dockd manages.

  An `Instance` is derived state: it is hydrated on demand from the Docker
  daemon (via `find_container/2` or `list_containers/2`) and is never
  long-lived. After a dockd process crashes or restarts, the world still
  looks the same — every `Dockd.apply/6`-created container carries the
  marker label `org.dockd.instance=true` and the instance name as
  `org.dockd.instance.name`, so `Dockd.list/2` can rebuild the full set of
  instances by querying Docker alone.

  The struct is intentionally minimal: it carries identity, the parts of
  the container's runtime configuration that callers commonly need, and a
  pre-computed `running?` flag. It does *not* carry the original `Spec`.
  After creation the container's filesystem is the source of truth for the
  effects of provisioning (copied host files, executed setup steps);
  reconstructing that intent post-hoc is neither necessary nor meaningful.

  Use `from_inspect/1` to build an `Instance` from a Docker inspect
  payload.
  """

  alias Dockd.Spec

  @type t :: %__MODULE__{
          id: binary(),
          name: binary(),
          image: binary() | nil,
          shell: binary() | nil,
          env: [binary()],
          mounts: [map()],
          labels: %{binary() => binary()},
          running?: boolean()
        }

  defstruct [
    :id,
    :name,
    :image,
    :shell,
    env: [],
    mounts: [],
    labels: %{},
    running?: false
  ]

  @marker_label "org.dockd.instance"
  @name_label "org.dockd.instance.name"

  @doc "Returns the discovery marker label key."
  @spec marker_label() :: binary()
  def marker_label, do: @marker_label

  @doc "Returns the instance-name label key."
  @spec name_label() :: binary()
  def name_label, do: @name_label

  @doc """
  Builds the dockd-managed label map for a container created from `spec`.

  The result is merged with any user-supplied labels at container-create
  time. `spec.instance_name` is already the short, user-facing name — the
  `dockd-` prefix belongs to the container name, not to the label.
  """
  @spec managed_labels(Spec.t()) :: %{binary() => binary()}
  def managed_labels(%Spec{instance_name: name}) do
    %{
      @marker_label => "true",
      @name_label => name
    }
  end

  @doc """
  Builds an `Instance` from a Docker inspect payload (the map returned by
  `Docker.find_container/2`).
  """
  @spec from_inspect(map()) :: t()
  def from_inspect(body) do
    config = Map.get(body, "Config", %{})
    host_config = Map.get(body, "HostConfig", %{})
    state = Map.get(body, "State", %{})

    %__MODULE__{
      id: Map.get(body, "Id"),
      name: name_from(body),
      image: Map.get(config, "Image"),
      shell: shell_from(config),
      env: Map.get(config, "Env") || [],
      mounts: mounts_from(host_config),
      labels: Map.get(config, "Labels") || %{},
      running?: Map.get(state, "Running") || false
    }
  end

  @doc """
  Returns the user-facing instance name (the container name with the
  `dockd-` prefix stripped).

  `nil` when the inspect payload carried no `"Name"` — `name_from/1` can produce
  that, so a guard here would raise on an `Instance` this module built itself.
  """
  @spec short_name(t()) :: binary() | nil
  def short_name(%__MODULE__{name: nil}), do: nil
  def short_name(%__MODULE__{name: name}), do: Spec.short_name(name)

  # ---------------------------------------------------------------------------

  defp name_from(%{"Name" => "/" <> rest}), do: rest
  defp name_from(%{"Name" => name}) when is_binary(name), do: name
  defp name_from(_), do: nil

  # The `interactive_shell` create-time sugar lands the requested shell as
  # the container's PID 1 Cmd, so we read it back from Config.Cmd.
  defp shell_from(%{"Cmd" => [shell | _]}) when is_binary(shell), do: shell
  defp shell_from(_), do: nil

  defp mounts_from(host_config) do
    binds =
      case Map.get(host_config, "Binds") do
        list when is_list(list) -> Enum.map(list, &%{type: :bind, source: &1})
        _ -> []
      end

    structured =
      case Map.get(host_config, "Mounts") do
        list when is_list(list) -> list
        _ -> []
      end

    binds ++ structured
  end
end
