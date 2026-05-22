defmodule Atlas.Workflow do
  @moduledoc """
  Input struct for an Atlas workflow run.

  `id` is `nil` until `Atlas.Workflows.run/1` assigns one.

  After a run finishes:
    * `output` is populated for every step that ran. The shape of each
      value is provider-defined (e.g. terraform returns
      `%{exit_status: 0 | 1}`).
    * `errors` is populated only for steps that ended in `:failed` or
      `:cancelled`, keyed by step id, with the value being the
      structured error list the provider returned.
  """

  alias Atlas.Workflow.Step

  @enforce_keys [:steps]
  defstruct id: nil, steps: [], output: %{}, errors: %{}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          steps: [Step.t()],
          output: %{String.t() => term()},
          errors: %{String.t() => [term()]}
        }
end
