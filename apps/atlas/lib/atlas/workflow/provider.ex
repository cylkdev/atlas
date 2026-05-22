defmodule Atlas.Workflow.Step.Provider do
  @moduledoc """
  Behavior for a step provider.

  Arguments:
    * `arguments` — the step's literal argument map.
    * `data` — a map keyed by upstream step id of every upstream
      step's `output`, surfaced from the upstream step's
      `:step_finished` event's `data.output`.
    * `ctx` — context giving the provider its `workflow_id` and its
      own `step_id`. Providers publish their own intermediate events
      by calling `Atlas.Workflows.PubSub.publish(ctx.workflow_id, event)`
      directly. Providers that want to receive live events should
      not call `subscribe/2` from within their task — the step
      server already forwards every matching event for the step's
      declared `subscribe_to` patterns to the Task's mailbox.

  Return values:
    * `:ok`                       — succeeded, output is `nil`.
    * `{:ok, output}`             — succeeded with this output. The
                                    output lands verbatim in
                                    `workflow.output[step_id]` and is
                                    also passed to downstream step
                                    servers through `data`.
    * `{:error, output}`          — failed with this output, no
                                    structured errors. `output` lands
                                    in `workflow.output[step_id]`;
                                    `workflow.errors[step_id]` is `[]`.
    * `{:error, output, errors}`  — failed with this output and a list
                                    of structured errors. `errors` is
                                    opaque to the runtime; whatever
                                    shape the provider chose lands
                                    verbatim in `workflow.errors[step_id]`.
  """

  @type ctx :: %{
          workflow_id: String.t(),
          step_id: String.t()
        }

  @callback call(arguments :: map(), data :: %{String.t() => term()}, ctx :: ctx()) ::
              :ok | {:ok, term()} | {:error, term()} | {:error, term(), [term()]}
end
