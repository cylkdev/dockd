defmodule Dockd.Error do
  @moduledoc """
  A phase-tagged failure from any step in the `Dockd` pipeline.

  Every error returned from `Dockd.prepare/2`, `Dockd.prepare_package/1`, `Dockd.destroy/1`,
  or `Dockd.Package.load/1` is wrapped in this struct. The `phase` field identifies which
  pipeline step failed (`:validate`, `:build`, `:pull`, `:create`, `:start`, `:fetch`,
  `:copy`, `:setup`, `:destroy`) so callers can route on it. When the failure happened after a container was
  created, `session` carries the partial `Dockd.Workspace` so the caller can clean up with
  `Dockd.destroy/1`. When the failure was a setup-step exit, `exit_code` and `output` are
  populated from the failing exec.

  Implements `Exception`, so it can be `raise`d as well as pattern-matched.

  ## Responsibilities

    - Tag a failure with the pipeline phase that produced it
    - Carry a human-readable `message` summarizing the cause
    - Attach the partial `Dockd.Workspace` when a container was created before the failure,
      so the caller knows what to destroy
    - Capture `exit_code` and `output` from a failing setup step's exec result
    - Normalize structured Docker reasons (status/body, exit_code, output) into a flat
      message + exit_code + output via `docker_phase_error/4`

  ## Examples

      iex> error = Dockd.Error.docker_phase_error(:create, "boom", "no such image", nil)
      iex> error.phase
      :create
      iex> error.message
      "boom: no such image"

  """

  # Abstraction Function:
  #   A %Dockd.Error{} represents a single failure point in the workspace lifecycle.
  #     - phase: which pipeline step failed (atom from a fixed set).
  #     - message: a human-readable summary, including any normalized reason text.
  #     - exit_code: for :setup failures, the non-zero exit code of the failing command;
  #       nil for non-exec failures.
  #     - output: for :setup failures, the captured stdout/stderr of the failing command;
  #       for HTTP/Docker errors, a body summary; nil otherwise.
  #     - session: the partial workspace state at the moment of failure - nil when no
  #       container had been created yet (e.g., :validate or :pull errors).
  #   Base case: %Dockd.Error{} with all fields nil represents a generic, unphased error;
  #   real errors always have at least :phase and :message populated.
  #
  # Data Invariant:
  #   1. When the error originates from `docker_phase_error/4`, :phase and :message are
  #      both non-nil binaries/atoms.
  #   2. :exit_code, when non-nil, is an integer extracted from the underlying reason.
  #   3. :output, when non-nil, is a binary - never a struct or arbitrary term.
  #   4. :session is either nil or a valid `Dockd.Workspace.t()`; never an arbitrary map.
  #
  # Commutative Diagram (docker_phase_error/4):
  #
  #   (:create, "failed to create", %{status: 409, body: "name in use"}, sess)
  #          |                                                                |
  #          | docker_phase_error                                             |
  #          v                                                                v
  #   %Error{phase: :create,                                                  |
  #          message: "failed to create: status=409 body=name in use",        |
  #          exit_code: nil, output: "name in use", session: sess}            |
  #          |                                                                |
  #         AF                                                               AF
  #          |                                                                |
  #          v                                                                v
  #     raw Docker reason   --docker_phase_error-->   normalized phase failure

  defexception [:phase, :message, :exit_code, :output, :session]

  @type t :: %__MODULE__{
          phase: atom() | nil,
          message: binary() | nil,
          exit_code: integer() | nil,
          output: binary() | nil,
          session: Dockd.Workspace.t() | nil
        }

  @spec docker_phase_error(atom(), binary(), term(), Dockd.Workspace.t()) :: t()
  def docker_phase_error(phase, message, reason, session) do
    %__MODULE__{
      phase: phase,
      message: message_with_reason(message, reason),
      exit_code: extract_exit_code(reason),
      output: extract_output(reason),
      session: session
    }
  end

  defp message_with_reason(message, reason) do
    "#{message}: #{reason_summary(reason)}"
  end

  defp reason_summary(%{status: status, body: body}),
    do: "status=#{status} body=#{body_summary(body)}"

  defp reason_summary(%{reason: reason}), do: reason_summary(reason)
  defp reason_summary(reason) when is_binary(reason), do: reason
  defp reason_summary(reason), do: inspect(reason)

  defp extract_exit_code(%{exit_code: exit_code}) when is_integer(exit_code), do: exit_code
  defp extract_exit_code(_reason), do: nil

  defp extract_output(%{output: output}) when is_binary(output), do: output
  defp extract_output(%{body: body}), do: body_summary(body)
  defp extract_output(reason) when is_binary(reason), do: reason
  defp extract_output(_reason), do: nil

  defp body_summary(body) when is_binary(body), do: body
  defp body_summary(body), do: inspect(body)
end
