defmodule Atlas.Providers.AWS.AutoScaling do
  @moduledoc """
  General-purpose workflow provider for AWS Auto Scaling. The `:action`
  argument selects the behaviour; each action has its own argument set.

  ## Action: `:listen`

  Waits for Auto Scaling lifecycle events delivered by
  `Atlas.EventBridgePlug` and published on `Atlas.AutoScaling.PubSub`,
  filtered to the ASG identified by the `name_prefix` from
  `deploys/terraform/compute.tf:223`.

  Required arguments:
    * `:action` (`:listen`).
    * `:name_prefix` (string) — the exact prefix declared on the ASG,
      for example `"atlas-release-cylk_web-staging-"`. Only events
      whose `auto_scaling_group_name` starts with this string are
      delivered to the step.
    * `:handler` (`{module(), atom()}`) — invoked synchronously with
      the matched `%AtlasSchemas.AutoScaling.Event{}` as its single
      argument before the event is added to the collected list. Must
      return `:ok`. Any other return value raises a `MatchError`
      inside the provider Task, which the step server records as a
      step failure.

  Optional arguments:
    * `:transitions` (`[String.t()] | :any`, default
      `["autoscaling:EC2_INSTANCE_LAUNCHING"]`).
    * `:count` (pos integer, default `1`) — events to collect before
      returning.
    * `:timeout_ms` (pos integer, default `600_000`).

  Return values:
    * Success → `{:ok, %{events: [event_map, …]}}` where each map has
      the durable fields from `AtlasSchemas.AutoScaling.Event`.
    * Timeout → `{:error, %{reason: :timeout, events: collected},
      [{:timeout, timeout_ms}]}`.
    * Cancelled → `{:error, :cancelled}`.
    * Missing required arg → `{:error, {:missing_argument, key}}`.
    * Unknown action → `{:error, {:invalid_action, action}}`.

  The Task running this provider also responds to a `:cancel` message,
  mirroring the convention in
  `apps/atlas/lib/atlas/workflows/providers/terraform.ex:152-156`.
  """

  @behaviour Atlas.Workflow.Step.Provider

  alias Atlas.AutoScaling.PubSub
  alias AtlasSchemas.AutoScaling.Event

  @default_transitions ["autoscaling:EC2_INSTANCE_LAUNCHING"]
  @default_count 1
  @default_timeout_ms 600_000

  @durable_fields [
    :id,
    :event_id,
    :source,
    :detail_type,
    :auto_scaling_group_name,
    :lifecycle_transition,
    :lifecycle_hook_name,
    :lifecycle_action_token,
    :ec2_instance_id,
    :received_at,
    :raw
  ]

  @impl true
  def call(arguments, _data, ctx) do
    with {:ok, action} <- fetch(arguments, :action),
         :ok <- validate_action(action) do
      dispatch(action, arguments, ctx)
    end
  end

  defp validate_action(:listen), do: :ok
  defp validate_action(other), do: {:error, {:invalid_action, other}}

  defp dispatch(:listen, arguments, ctx) do
    with {:ok, name_prefix} <- fetch(arguments, :name_prefix),
         {:ok, handler} <- fetch(arguments, :handler) do
      opts = %{
        name_prefix: name_prefix,
        transitions: Map.get(arguments, :transitions, @default_transitions),
        count: Map.get(arguments, :count, @default_count),
        timeout_ms: Map.get(arguments, :timeout_ms, @default_timeout_ms),
        handler: handler
      }

      Atlas.Log.info(
        log_id(ctx),
        "subscribing to auto-scaling events for name_prefix=#{opts.name_prefix}"
      )

      :ok = PubSub.subscribe()

      try do
        collect([], opts, ctx)
      after
        PubSub.unsubscribe()
      end
    end
  end

  defp collect(acc, %{count: count} = _opts, ctx) when length(acc) >= count do
    Atlas.Log.info(log_id(ctx), "collected #{length(acc)} auto-scaling event(s)")

    {:ok, %{events: Enum.map(Enum.reverse(acc), &event_to_map/1)}}
  end

  defp collect(acc, opts, ctx) do
    receive do
      :cancel ->
        Atlas.Log.warn(log_id(ctx), "cancel signal received, exiting listener")
        {:error, :cancelled}

      {:auto_scaling_event, %Event{} = event} ->
        if matches?(event, opts) do
          Atlas.Log.info(
            log_id(ctx),
            "matched event for #{event.auto_scaling_group_name} transition=#{event.lifecycle_transition}"
          )

          invoke_handler(event, opts.handler, ctx)
          collect([event | acc], opts, ctx)
        else
          collect(acc, opts, ctx)
        end
    after
      opts.timeout_ms ->
        Atlas.Log.error(
          log_id(ctx),
          "timed out after #{opts.timeout_ms}ms waiting for auto-scaling events"
        )

        {:error, %{reason: :timeout, events: Enum.map(Enum.reverse(acc), &event_to_map/1)},
         [{:timeout, opts.timeout_ms}]}
    end
  end

  defp matches?(%Event{} = event, %{name_prefix: prefix, transitions: transitions}) do
    name_match =
      is_binary(event.auto_scaling_group_name) and
        String.starts_with?(event.auto_scaling_group_name, prefix)

    transition_match =
      case transitions do
        :any -> true
        list when is_list(list) -> event.lifecycle_transition in list
      end

    name_match and transition_match
  end

  defp invoke_handler(%Event{} = event, {module, function}, _ctx)
       when is_atom(module) and is_atom(function) do
    :ok = apply(module, function, [event])
  end

  defp event_to_map(%Event{} = event), do: Map.take(event, @durable_fields)

  defp log_id(ctx), do: "workflow:#{ctx.workflow_id}:#{ctx.step_id}"

  defp fetch(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_argument, key}}
    end
  end
end
