defmodule Atlas.Application do
  @moduledoc """
  Starts the `atlas` application.

  Supervises the children the domain service node needs to run:

  - One `Oban` instance bound to `AtlasSchemas.Repo` for background
    Stripe event processing (`:stripe` queue, concurrency `10`).
  - `Atlas.AutoScaling.PubSub` — Registry-backed pubsub for
    EventBridge auto-scaling lifecycle events.
  - `Atlas.Endpoint` — Bandit + `Atlas.EventBridgePlug` so EventBridge
    can POST lifecycle events into the node.
  - `Atlas.Workflows.Supervisor` — workflow runtime (Registry,
    PubSub, Task.Supervisor, Orchestrator DynamicSupervisor).

  PubSub starts before `Atlas.Endpoint` so the very first plug request
  cannot race the Registry's startup.
  """

  use Application

  @impl true
  @spec start(term(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = [
      {Oban,
       [
         repo: AtlasSchemas.Repo,
         queues: [stripe: 10],
         plugins: [Oban.Plugins.Pruner]
       ]},
      Atlas.AutoScaling.PubSub,
      Atlas.Endpoint,
      Atlas.Workflows.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Atlas.Supervisor)
  end
end
