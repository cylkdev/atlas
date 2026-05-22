defmodule Atlas.Workflows.Supervisor do
  @moduledoc """
  Application-level supervisor for the workflow runtime.

  Children:
    * `Atlas.Workflows.Registry` — `Registry` with `:unique` keys.
      Orchestrators register under `{:orchestrator, workflow_id}`.
    * `Atlas.Workflows.PubSub` — `Registry` with `:duplicate` keys
      used by `Atlas.Workflows.PubSub` for event dispatch.
    * `Atlas.Workflows.TaskSupervisor` — `Task.Supervisor` for
      provider calls launched by step servers.
    * `Atlas.Workflows.OrchestratorSupervisor` — `DynamicSupervisor`
      that starts one `Atlas.Workflows.Orchestrator` per run.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Atlas.Workflows.Registry},
      Atlas.Workflows.PubSub,
      {Task.Supervisor, name: Atlas.Workflows.TaskSupervisor},
      {DynamicSupervisor, name: Atlas.Workflows.OrchestratorSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
