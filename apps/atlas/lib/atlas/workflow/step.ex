defmodule Atlas.Workflow.Step do
  @moduledoc """
  One step in an `Atlas.Workflow`.

  `depends_on` accepts only literal entries:
    * `"step_id"` — runs after that step reaches `:succeeded`. If it
      reaches any other terminal status, the depending step is
      `:skipped`.
    * `{"step_id", :succeeded}` — same as above, explicit.
    * `{"step_id", :failed}` — runs after that step reaches `:failed`.
      If it succeeds instead, the depending step is `:skipped`.

  `subscribe_to` is a list of event-name pattern lists (each relative
  to `["workflow", workflow_id]`). The step server registers a
  subscription for each pattern from the moment it is spawned, so it
  cannot miss early matches. Every matching event the workflow
  publishes is delivered to the step server. The string `"*"` is the
  wildcard segment; it matches one or more name segments.

  The step server starts its provider only after **each** subscription
  has received at least one matching event (in addition to all
  `depends_on` step terminals having been observed). Events are not
  stored — only a boolean per pattern is tracked. Once the provider
  Task is running, the step server forwards every live matching event
  to the Task's mailbox; the provider can `receive` them.

  Example:

      %Step{
        id: "configure",
        provider: Atlas.Providers.Ansible,
        arguments: %{playbook: "/infra/configure.yml"},
        subscribe_to: [["terraform", "aws_autoscaling_group", "created", "*"]]
      }
  """

  alias Atlas.Workflow.Retry

  @enforce_keys [:id, :provider]
  defstruct [
    :id,
    :provider,
    arguments: %{},
    depends_on: [],
    subscribe_to: [],
    timeout: :infinity,
    retry: %Retry{},
    metadata: %{}
  ]

  @type dependency :: String.t() | {String.t(), :succeeded | :failed}
  @type pattern :: [String.t()]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: module(),
          arguments: map(),
          depends_on: [dependency()],
          subscribe_to: [pattern()],
          timeout: :infinity | non_neg_integer(),
          retry: Retry.t(),
          metadata: map()
        }
end
