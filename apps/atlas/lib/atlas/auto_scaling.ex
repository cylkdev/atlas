defmodule Atlas.AutoScaling do
  @moduledoc """
  Receives EventBridge auto-scaling lifecycle envelopes, persists them
  to `auto_scaling_events`, and publishes them on
  `Atlas.AutoScaling.PubSub`.

  ## Getting Started

  ```
  {:ok, event} = Atlas.AutoScaling.handle_event(envelope)
  {:ok, _resp} = Atlas.AutoScaling.complete_lifecycle_action(event, :continue)
  ```

  Non-auto-scaling envelopes return `:ignored` so the plug can
  acknowledge them with a `200` without triggering EventBridge
  retries.
  """

  alias AtlasSchemas.AutoScaling, as: Schemas
  alias AtlasSchemas.AutoScaling.Event

  alias Atlas.AutoScaling.PubSub

  @auto_scaling_source "aws.autoscaling"

  @spec handle_event(map()) ::
          {:ok, Event.t()} | :ignored | {:error, ErrorMessage.t()}
  def handle_event(%{"source" => @auto_scaling_source} = envelope) do
    with {:ok, params} <- envelope_to_params(envelope),
         {:ok, event} <- upsert_event(params) do
      :ok = PubSub.publish(event)
      {:ok, event}
    end
  end

  def handle_event(_other), do: :ignored

  @doc """
  When an ASG-launched instance hits the hook, AWS parks it in a wait state
  (Pending:Wait for a launch hook). The instance stays parked until someone
  calls CompleteLifecycleAction. That API call takes LifecycleActionResult,
  which has exactly two valid values:

  - "CONTINUE" — finish the launch. AWS registers the instance with the
  target group and moves it to InService.
  - "ABANDON" — fail the launch. AWS terminates the instance; the ASG
  launches a replacement
  """
  def complete_lifecycle_action(%Event{} = event, result)
      when result in [:abandon, :continue, "ABANDON", "CONTINUE"] do
    AWS.AutoScaling.complete_lifecycle_action(
      lifecycle_hook_name: event.lifecycle_hook_name,
      auto_scaling_group_name: event.auto_scaling_group_name,
      lifecycle_action_token: event.lifecycle_action_token,
      instance_id: event.ec2_instance_id,
      lifecycle_action_result: lifecycle_action_result(result)
    )
  end

  defp lifecycle_action_result(:abandon), do: "ABANDON"
  defp lifecycle_action_result(:continue), do: "CONTINUE"
  defp lifecycle_action_result("ABANDON"), do: "ABANDON"
  defp lifecycle_action_result("CONTINUE"), do: "CONTINUE"

  defp envelope_to_params(envelope) do
    detail = envelope["detail"] || %{}

    case detail["AutoScalingGroupName"] do
      nil ->
        {:error,
         ErrorMessage.bad_request("missing detail.AutoScalingGroupName", %{
           envelope: envelope
         })}

      asg_name ->
        {:ok,
         %{
           event_id: envelope["id"],
           source: envelope["source"],
           detail_type: envelope["detail-type"],
           auto_scaling_group_name: asg_name,
           lifecycle_transition: detail["LifecycleTransition"],
           lifecycle_hook_name: detail["LifecycleHookName"],
           lifecycle_action_token: detail["LifecycleActionToken"],
           ec2_instance_id: detail["EC2InstanceId"],
           received_at: DateTime.utc_now(),
           raw: envelope
         }}
    end
  end

  defp upsert_event(%{event_id: event_id} = params) do
    case Schemas.find_event(%{event_id: event_id}) do
      {:ok, existing} -> {:ok, existing}
      {:error, %{code: :not_found}} -> Schemas.create_event(params)
    end
  end
end
