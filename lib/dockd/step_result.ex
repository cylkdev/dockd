defmodule Dockd.StepResult do
  @moduledoc """
  The captured outcome of a single setup step that ran inside a Dockd container.

  Each step from a `Dockd.prepare/2` `:steps` list produces one of these in
  `Dockd.Session.step_results`, in input order. Together with the step's `:label` and
  `:cmd`, the struct preserves the env/workdir/user the step ran with, the captured
  combined stdout+stderr, and the process exit code.

  ## Responsibilities

    - Pair a step's input identity (label, cmd, env, workdir, user) with its run-time
      outcome (output, exit_code) so callers can correlate a result back to its spec
    - Preserve the original `cmd` argv list as binaries for replay or diagnostic display
    - Distinguish "ran and exited 0" from "ran and exited non-zero" via `exit_code`,
      while leaving room for `nil` when an exit code wasn't reported by Docker

  ## Examples

      iex> %Dockd.StepResult{label: "ok", cmd: ["true"], output: "", exit_code: 0}.exit_code
      0

  """

  # Abstraction Function:
  #   A %Dockd.StepResult{} represents one completed setup step in a Dockd workspace.
  #     - label: the human-readable name the step was given in the spec.
  #     - cmd: the argv list that was exec'd inside the container.
  #     - output: the combined stdout+stderr captured from the exec.
  #     - exit_code: the integer status the command exited with, or nil if Docker did
  #       not report one.
  #     - env / workdir / user: the per-step exec options the step ran with, copied from
  #       the spec; nil when the spec did not set them.
  #   Base case: %Dockd.StepResult{} with all fields nil/empty has no meaningful
  #   interpretation — every materialized step result has at least :label, :cmd, and
  #   :output populated.
  #
  # Data Invariant:
  #   1. :label is a non-empty binary — always populated when the step ran.
  #   2. :cmd is a non-empty list of binaries — the argv that was exec'd.
  #   3. :output is a binary (possibly empty), never nil — the capture is always defined.
  #   4. :exit_code is either an integer or nil; never a binary or other type.
  #   5. :env, when non-nil, is a list of binaries; :workdir and :user, when non-nil,
  #      are binaries.

  @type t :: %__MODULE__{
          label: binary(),
          cmd: [binary()],
          output: binary(),
          exit_code: integer() | nil,
          env: [binary()] | nil,
          workdir: binary() | nil,
          user: binary() | nil
        }

  defstruct [:label, :cmd, :output, :exit_code, :env, :workdir, :user]
end
