defmodule Atlas.Application do
  @moduledoc """
  Starts the `atlas` application.

  Supervises the children the domain service node needs to run:

  - `Atlas.ObanManager` — one named Oban instance bound to
    `AtlasSchemas.Config.repo/0`. Engine and per-env overrides are
    configured via `config :atlas, Oban, ...`. See `Atlas.ObanManager`
    for details.
  - `Atlas.AutoScaling.PubSub` — Registry-backed pubsub for
    EventBridge auto-scaling lifecycle events.
  - `Atlas.Endpoint` — Bandit + `Atlas.EventBridgePlug` so EventBridge
    can POST lifecycle events into the node. **Always supervised, but
    only binds a port when `Atlas.Endpoint.server?/0` is `true`** —
    i.e. when the consumer sets `config :atlas, Atlas.Endpoint,
    server: true` or when the node was booted via `mix atlas.server`
    (which sets `config :atlas, :serve_endpoints, true`). The
    supervisor itself starts unconditionally so the supervision-tree
    shape is stable across boots; the serve / don't-serve decision
    lives in `Atlas.Endpoint.init/1`.
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
      Atlas.ObanManager.supervisor_child_spec(),
      Atlas.AutoScaling.PubSub,
      Atlas.Endpoint,
      Atlas.Workflows.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Atlas.Supervisor)
  end
end
