defmodule Mix.Tasks.Atlas.Workflows.Deploy do
  @shortdoc "Run the deployment workflow (terraform plan + apply)"

  @moduledoc """
  Runs `Atlas.Pipeline.for_deployment/1` end-to-end: `terraform plan` writes
  a saved plan, then `terraform apply` consumes it. Blocks until the workflow
  finishes.

      mix atlas.workflows.deploy

  Exits with status 1 if any step failed or the run timed out.

  ## Tunnel reachability

  The pipeline includes an `aws.auto_scaling.listen` step whose
  webhook target must be reachable from AWS EventBridge. This task
  does **not** start or stop a Cloudflare tunnel — by design, tunnel
  lifecycle is owned by `mix atlas.tunnels.start`, which is run as
  its own separate process. The operator is responsible for bringing
  the tunnel up (in a separate terminal, systemd unit, or CI
  background step) before invoking this task, and tearing it down
  afterwards.
  """

  use Mix.Task

  @requirements ["app.start", "atlas.init"]
  @await_timeout :timer.minutes(30)

  @impl Mix.Task
  def run(_argv) do
    workflow_id = generate_id()
    Atlas.Log.info("workflow:#{workflow_id}", "deployment task starting")

    workflow = Atlas.Pipeline.for_deployment(workflow_id)

    case Atlas.Workflows.run(workflow, await: true, await_timeout: @await_timeout) do
      {:ok, %Atlas.Workflow{errors: errors} = final} when map_size(errors) == 0 ->
        Atlas.Log.info("workflow:#{final.id}", "deployment task succeeded")

      {:ok, %Atlas.Workflow{} = final} ->
        Enum.each(final.errors, fn {step_id, errs} ->
          Atlas.Log.error(
            "workflow:#{final.id}:#{step_id}",
            "#{length(errs)} diagnostic(s)"
          )
        end)

        Atlas.Log.error("workflow:#{final.id}", "deployment task failed")
        exit({:shutdown, 1})

      {:error, reason} ->
        Atlas.Log.error("workflow:#{workflow_id}", "run returned #{inspect(reason)}")
        Mix.raise("deployment workflow failed: #{inspect(reason)}")
    end
  end

  defp generate_id do
    "deploy-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  end
end
