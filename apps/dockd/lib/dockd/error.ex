defmodule Dockd.Error do
  @moduledoc """
  A phase-tagged failure from any step in the `Dockd` pipeline.

  Every error returned from `Dockd.apply/2`, `Dockd.destroy/1`,
  `Dockd.list/1`, or `Dockd.get/2` is wrapped in this struct. The `phase`
  field identifies which pipeline step failed (`:validate`, `:build`,
  `:pull`, `:create`, `:start`, `:fetch`, `:copy`, `:setup`, `:destroy`,
  `:discover`) so callers can route on it. When the failure happened after
  a container was created, `instance` carries a hydrated `Dockd.Instance`
  so the caller can clean up with `Dockd.destroy/1`. When the failure was
  a setup-step exit, `exit_code` and `output` are populated from the
  failing exec.

  Implements `Exception`, so it can be `raise`d as well as
  pattern-matched.
  """

  defexception [:phase, :message, :exit_code, :output, :instance, step_results: []]

  @type t :: %__MODULE__{
          phase: atom() | nil,
          message: binary() | nil,
          exit_code: integer() | nil,
          output: binary() | nil,
          instance: Dockd.Instance.t() | nil,
          step_results: [Dockd.StepResult.t()]
        }

  @spec docker_phase_error(atom(), binary(), term(), Dockd.Instance.t() | nil) :: t()
  def docker_phase_error(phase, message, reason, instance) do
    %__MODULE__{
      phase: phase,
      message: message_with_reason(message, reason),
      exit_code: extract_exit_code(reason),
      output: extract_output(reason),
      instance: instance,
      step_results: []
    }
  end

  @spec bad_request(binary(), term(), keyword()) :: t()
  def bad_request(message, reason, _opts \\ []) do
    docker_phase_error(:rpc, message, reason, nil)
  end

  @spec service_unavailable(binary(), term(), keyword()) :: t()
  def service_unavailable(message, reason, _opts \\ []) do
    docker_phase_error(:rpc, message, reason, nil)
  end

  @spec request_timeout(binary(), term(), keyword()) :: t()
  def request_timeout(message, reason, _opts \\ []) do
    docker_phase_error(:rpc, message, reason, nil)
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
