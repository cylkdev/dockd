defmodule Dockd.ApplyResult do
  @moduledoc """
  The outcome of a single `Dockd.apply/6` call.

  Carries the resulting `Dockd.Instance` (the view of the just-created
  container) plus the ordered list of `Dockd.StepResult`s captured from
  the spec's setup steps. The result is meant to be consumed by the caller
  and discarded — neither the `Instance` nor the `step_results` are
  persisted by dockd.
  """

  alias Dockd.Instance
  alias Dockd.StepResult

  # :instance is enforced, not merely typed non-nil: an ApplyResult without one
  # describes nothing. A failed apply carries its partial instance on the
  # `%ErrorMessage{}`'s `details.instance` instead, so there is no case that
  # needs a nil here.
  @enforce_keys [:instance]

  @type t :: %__MODULE__{
          instance: Instance.t(),
          step_results: [StepResult.t()]
        }

  defstruct [:instance, step_results: []]
end
