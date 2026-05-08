defmodule Dockd.Session do
  @moduledoc """
  The state of a single Docker workspace tracked by `Dockd`.

  A session bundles together everything a caller needs to operate on a prepared container:
  the Docker container ID and name, the image and shell it was started with, the cached
  `docker exec -it` invocation for attaching, the ordered results of any setup commands
  that have run, and the Docker connection options used to create it.

  ## Responsibilities

    - Hold the identity of a Docker container (`container_id`, `container_name`) and the
      image and shell it was launched with
    - Cache the `shell_command` string so callers don't rebuild it from parts
    - Preserve the order of `step_results` to match the input setup steps one-to-one
    - Carry forward the Docker connection options used to create the container so later
      operations on the same session reach the same daemon

  ## Examples

      iex> session = Dockd.Session.new(%{container_name: "dockd-1", shell: "/bin/bash"})
      iex> session.shell_command
      "docker exec -it dockd-1 /bin/bash"

      iex> session = Dockd.Session.new(%{container_name: "dockd-2", shell: "/bin/sh"})
      iex> updated = Dockd.Session.put(session, %{container_id: "abc123"})
      iex> updated.container_id
      "abc123"

  """

  # Abstraction Function:
  #   A %Session{} represents a Docker workspace at one point in its lifecycle.
  #     - container_id: the Docker-assigned ID; nil before the create phase has run.
  #     - container_name: the human-readable name reserved for the container; non-nil
  #       once the workspace has been requested, even before the container exists.
  #     - image: the registry reference pulled or the tag built; the source the container
  #       was launched from.
  #     - shell: the binary inside the container that an interactive attach should exec.
  #     - shell_command: the cached `docker exec -it <name> <shell>` string, derived from
  #       container_name and shell — semantically redundant with those fields, kept for
  #       caller convenience.
  #     - step_results: the ordered outcomes of the setup commands that have completed
  #       so far, parallel to the input :steps list up to whatever index has run.
  #     - docker_options: the connection/creation options carried forward so destroy
  #       and exec calls reach the same daemon used to create the container.
  #   Base case: a session with container_id == nil and step_results == [] represents
  #   a workspace that has been requested but not yet realized as a Docker container.
  #
  # Data Invariant:
  #   1. step_results is always a list (default []), never nil.
  #   2. docker_options is always a keyword list (default []), never nil.
  #   3. When container_name and shell are both non-nil, shell_command equals
  #      shell_command/1 of the same struct — the cache is consistent with its inputs.
  #   4. If step_results is non-empty, container_id is non-nil — results can only exist
  #      after a container has been created and started.
  #
  # Commutative Diagram (put/2):
  #
  #   %Session{name: "dockd-1", shell: "/bin/sh", id: nil}
  #          |                                            |
  #          | put(%{container_id: "abc"})                |
  #          v                                            v
  #   %Session{name: "dockd-1", shell: "/bin/sh", id: "abc",
  #            shell_command: "docker exec -it dockd-1 /bin/sh"}
  #          |                                            |
  #         AF                                           AF
  #          |                                            |
  #          v                                            v
  #     requested workspace  --put(id: "abc")-->   created workspace

  @type t :: %__MODULE__{
          container_id: binary() | nil,
          container_name: binary() | nil,
          image: binary() | nil,
          shell: binary() | nil,
          shell_command: binary() | nil,
          step_results: [Dockd.StepResult.t()],
          docker_options: keyword()
        }

  defstruct [
    :container_id,
    :container_name,
    :image,
    :shell,
    :shell_command,
    step_results: [],
    docker_options: []
  ]

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    session = struct(__MODULE__, Map.to_list(attrs))
    %{session | shell_command: shell_command(session)}
  end

  @spec put(t(), map()) :: t()
  def put(%__MODULE__{} = session, attrs) when is_map(attrs) do
    session
    |> Map.merge(attrs)
    |> then(&struct(__MODULE__, Map.to_list(&1)))
    |> then(fn updated -> %{updated | shell_command: shell_command(updated)} end)
  end

  @spec shell_command(t()) :: binary()
  def shell_command(%__MODULE__{container_name: container_name, shell: shell}) do
    ["docker", "exec", "-it", shell_escape(container_name), shell_escape(shell)]
    |> Enum.join(" ")
  end

  defp shell_escape(value) when is_binary(value) do
    if value == "" or not String.match?(value, ~r/^[A-Za-z0-9_@%+=:,.\/-]+$/) do
      escaped = String.replace(value, "'", ~s('"'"'))
      "'#{escaped}'"
    else
      value
    end
  end
end
