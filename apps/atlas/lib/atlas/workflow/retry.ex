defmodule Atlas.Workflow.Retry do
  @moduledoc """
  Retry policy for a step.

  `max` is the maximum number of additional attempts after the initial
  run. `max: 0` (default) means no retries. `on` lists which failure
  triggers cause a retry.
  """

  defstruct max: 0, backoff: :none, on: [:error]

  @type backoff :: :none | :linear | :exponential | {:fixed, non_neg_integer()}
  @type trigger :: :error | :timeout | :exit_status

  @type t :: %__MODULE__{
          max: non_neg_integer(),
          backoff: backoff(),
          on: [trigger()]
        }
end
