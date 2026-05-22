
```elixir
defmodule Atlas.Workflows.Store do
  def get_private(store_module, workflow_id, resource_id) do
    store_module.get_private(workflow_id, resource_id)
  end

  def put_private(store_module, workflow_id, resource_id, value) do
    store_module.put_private(workflow_id, resource_id, value)
  end
end
```

```elixir
%Atlas.Workflow{
  id: "workflow-123",
  status: :unresolved,
  store: Atlas.Workflows.Stores.ETS,
  steps: [
    %Atlas.Workflow.Step{
      id: "step_a",
      provider: Atlas.Providers.Command,
      args: %{
        executable: "bash",
        arguments: ["-c", "echo This is step a"],
        parse: :ndjson
      },
      depends_on: [],
      on_success: Atlas.Workflows.Policies.OnCommandSuccess,
      on_failure: Atlas.Workflows.Policies.FailWorkflow,
      timeout: <nil | :infinity | non_neg_integer()>,
      retry: %Atlas.Workflow.Retry{
        max: 3,
        backoff: :exponential,
        on: [:timeout, :exit_status]
      }
    }
    %Atlas.Workflow.Step{
      id: "step_b",
      provider: Atlas.Providers.Command,
      args: %{
        executable: "bash",
        arguments: ["-c", "echo This is step b"],
        parse: :ndjson
      },
      depends_on: ["step_a"],
      on_success: Atlas.Workflows.Policies.OnCommandSuccess,
      on_failure: Atlas.Workflows.Policies.FailWorkflow,
      timeout: <nil | :infinity | non_neg_integer()>,
      retry: %Atlas.Workflow.Retry{
        max: 3,
        backoff: :exponential,
        on: [:timeout, :exit_status]
      }
    }
  ],
  errors: []
}
```

```elixir
defmodule Atlas.Workflows do
  alias Atlas.Workflows.Store

  def run_step(%Atlas.Workflow.Step{} = step, %Atlas.Workflow{} = workflow) do
    # Execute the command and return the result
    result = step.provider.call(step.args, workflow)
    # Store the result in the workflow store
    Store.put_private(workflow.store, workflow.id, step.id, result)
    
    workflow
  end
end
```