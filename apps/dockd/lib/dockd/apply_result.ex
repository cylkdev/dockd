defmodule Dockd.ApplyResult do
  @moduledoc """
  The outcome of a single `Dockd.apply/2` call.

  Carries the resulting `Dockd.Instance` (the view of the just-created
  container) plus the ordered list of `Dockd.StepResult`s captured from
  the spec's setup steps. The result is meant to be consumed by the caller
  and discarded — neither the `Instance` nor the `step_results` are
  persisted by dockd.
  """

  alias Dockd.Instance
  alias Dockd.StepResult

  @type t :: %__MODULE__{
          instance: Instance.t(),
          step_results: [StepResult.t()]
        }

  defstruct [:instance, step_results: []]
end
