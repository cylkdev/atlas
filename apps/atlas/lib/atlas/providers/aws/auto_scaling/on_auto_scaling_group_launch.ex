defmodule Atlas.Providers.AWS.AutoScaling.OnAutoScalingGroupLaunch do
  @moduledoc """
  Handles `EC2 Instance-launch Lifecycle Action` events delivered by
  `Atlas.Providers.AWS.AutoScalingListener`.

  Invoked once per matched event when the provider is configured with
  `handler: {Atlas.Providers.AWS.AutoScaling.OnAutoScalingGroupLaunch, :handle}`. The provider
  has already filtered events by `name_prefix` and `lifecycle_transition`
  before the handler runs, so every event delivered here belongs to the
  ASG identified by the workflow's `name_prefix`.

  The handler logs the event and returns `:ok`. Releasing the lifecycle
  hook (via `Atlas.AutoScaling.complete_lifecycle_action/2`) is a
  separate concern owned by the downstream deploy step — calling it
  here would let the instance enter `InService` before Ansible runs,
  defeating the purpose of the `Pending:Wait` hook.
  """

  alias AtlasSchemas.AutoScaling.Event

  @spec handle(Event.t()) :: :ok
  def handle(%Event{} = event) do
    Atlas.Log.info(
      "auto_scaling:launch_handler",
      "received launch event instance=#{event.ec2_instance_id} " <>
        "asg=#{event.auto_scaling_group_name} hook=#{event.lifecycle_hook_name}"
    )

    :ok
  end
end
