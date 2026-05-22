defmodule Atlas.AutoScaling.PubSub do
  @moduledoc """
  Pubsub for auto-scaling lifecycle events received from EventBridge.

  Backed by a `Registry` with `:duplicate` keys, registered name
  `Atlas.AutoScaling.PubSub.Registry`. All subscribers register under
  the same key (`:events`) and receive every published event;
  filtering by `auto_scaling_group_name` prefix is the subscriber's
  responsibility — event volume is low (one event per instance
  launch), so local filtering is cheap.

  Public surface:

    * `subscribe/0` — registers the calling pid.
    * `unsubscribe/0` — removes the calling pid's registration.
    * `publish/1` — sends `{:auto_scaling_event, event}` to every
      registered pid.

  No event is buffered. `publish/1` dispatches synchronously in the
  calling process. Subscribers that die are removed automatically by
  `Registry`.
  """

  alias AtlasSchemas.AutoScaling.Event

  @registry __MODULE__.Registry
  @key :events

  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @spec subscribe() :: :ok
  def subscribe do
    {:ok, _} = Registry.register(@registry, @key, [])
    :ok
  end

  @spec unsubscribe() :: :ok
  def unsubscribe do
    Registry.unregister(@registry, @key)
    :ok
  end

  @spec publish(Event.t()) :: :ok
  def publish(%Event{} = event) do
    Registry.dispatch(@registry, @key, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, {:auto_scaling_event, event}) end)
    end)

    :ok
  end
end
