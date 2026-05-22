defmodule Atlas.Workflows.PubSub do
  @moduledoc """
  Pubsub for workflow events.

  Backed by a `Registry` with `:duplicate` keys (one registry process
  for the whole runtime, named `Atlas.Workflows.PubSub.Registry`). A
  subscription is one Registry entry per `(workflow_id, compiled_pattern)`
  pair, with the subscriber pid as the entry's owner.

  Public surface:

    * `subscribe(workflow_id, pattern)` — registers the calling pid
      against the relative pattern (compiled into a name list
      anchored at `["workflow", workflow_id | …]`).
    * `unsubscribe(workflow_id, pattern)` — removes one registration
      for the calling pid.
    * `publish(workflow_id, %Event{})` — for each registration under
      `workflow_id`, checks whether the compiled pattern matches the
      event's name list; if so, sends `{:workflow_event, event}` to
      the registered pid. Pids with multiple matching patterns
      receive the event exactly once.

  No event is buffered. `publish/2` dispatches synchronously to all
  matching subscribers in the calling process. Subscribers that die
  are removed automatically by `Registry`.
  """

  alias Atlas.Workflows.Event
  alias Atlas.Workflows.Event.Pattern

  @registry __MODULE__.Registry

  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @spec subscribe(String.t(), [String.t()]) :: :ok
  def subscribe(workflow_id, pattern)
      when is_binary(workflow_id) and is_list(pattern) do
    compiled = Pattern.compile(pattern, workflow_id)
    {:ok, _} = Registry.register(@registry, workflow_id, compiled)
    :ok
  end

  @spec unsubscribe(String.t(), [String.t()]) :: :ok
  def unsubscribe(workflow_id, pattern)
      when is_binary(workflow_id) and is_list(pattern) do
    compiled = Pattern.compile(pattern, workflow_id)
    Registry.unregister_match(@registry, workflow_id, compiled)
    :ok
  end

  @spec publish(String.t(), Event.t()) :: :ok
  def publish(workflow_id, %Event{name: name} = event) when is_binary(workflow_id) do
    Registry.dispatch(@registry, workflow_id, fn entries ->
      entries
      |> Enum.filter(fn {_pid, compiled} -> Pattern.matches?(compiled, name) end)
      |> Enum.uniq_by(fn {pid, _compiled} -> pid end)
      |> Enum.each(fn {pid, _compiled} -> send(pid, {:workflow_event, event}) end)
    end)

    :ok
  end
end
