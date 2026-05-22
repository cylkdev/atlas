defmodule Atlas.Workflows.Orchestrator do
  @moduledoc """
  One GenServer per workflow run. Responsibilities:

    * Spawn one `Atlas.Workflow.Step.Server` per step.
    * Subscribe (via `Atlas.Workflows.PubSub`) to every step-lifecycle
      event in this workflow (`["step", "*", "*"]`) so it can track
      step terminal status, populate `step_statuses` / `step_reasons`,
      and detect workflow finalization.
    * Publish `Event.workflow_finished/2` when all steps are terminal.
    * Handle `status/1` and `cancel/1` calls.

  The orchestrator is **not** a pubsub hub. All event routing happens
  in `Atlas.Workflows.PubSub`. Anyone who wants events — step servers,
  the orchestrator itself, external callers — subscribes there.

  Restart strategy is `:temporary` — state is in-memory.
  """

  use GenServer, restart: :temporary

  alias Atlas.Workflow
  alias Atlas.Workflows.Event
  alias Atlas.Workflows.PubSub
  alias Atlas.Workflow.Step.Server, as: StepServer

  @registry Atlas.Workflows.Registry
  @final_ttl_ms 60_000

  def child_spec(%Workflow{} = workflow) do
    %{
      id: {__MODULE__, workflow.id},
      start: {__MODULE__, :start_link, [workflow]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(%Workflow{} = workflow) do
    GenServer.start_link(__MODULE__, workflow)
  end

  @impl true
  def init(%Workflow{} = workflow) do
    Process.flag(:trap_exit, true)

    case Registry.register(@registry, {:orchestrator, workflow.id}, nil) do
      {:ok, _} ->
        :ok = PubSub.subscribe(workflow.id, ["step", "*", "*"])

        Atlas.Log.info(
          "workflow:#{workflow.id}",
          "orchestrator started, #{length(workflow.steps)} step(s)"
        )

        state = %{
          workflow: workflow,
          status: :running,
          step_statuses: Map.new(workflow.steps, fn s -> {s.id, :pending} end),
          step_outputs: %{},
          step_errors: %{},
          step_servers: %{},
          started_at: DateTime.utc_now(),
          updated_at: nil,
          finished_at: nil
        }

        {:ok, state, {:continue, :spawn_step_servers}}

      {:error, {:already_registered, _}} ->
        Atlas.Log.warn(
          "workflow:#{workflow.id}",
          "rejected — orchestrator already running for this id"
        )

        {:stop, {:shutdown, :duplicate_workflow_id}}
    end
  end

  @impl true
  def handle_continue(:spawn_step_servers, state) do
    wf_id = state.workflow.id

    {servers, state} =
      Enum.reduce(state.workflow.steps, {[], state}, fn step, {pids, acc} ->
        {:ok, pid} =
          GenServer.start_link(StepServer, %{
            step: step,
            workflow_id: wf_id,
            orchestrator: self(),
            depends_on_ids: depends_on_ids(step.depends_on)
          })

        acc = %{acc | step_servers: Map.put(acc.step_servers, step.id, pid)}
        {[pid | pids], acc}
      end)

    Enum.each(servers, fn pid -> send(pid, :go) end)
    {:noreply, maybe_finalize(state)}
  end

  @impl true
  def handle_info({:workflow_event, %Event{} = event}, state) do
    state = apply_event(state, event)
    {:noreply, maybe_finalize(state)}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    step_id =
      Enum.find_value(state.step_servers, fn
        {id, ^pid} -> id
        _ -> nil
      end)

    state =
      if step_id,
        do: %{state | step_servers: Map.delete(state.step_servers, step_id)},
        else: state

    state =
      if step_id && Map.get(state.step_statuses, step_id) == :pending do
        event = Event.step_failed(state.workflow.id, step_id, {:server_exit, reason}, [], 0)
        PubSub.publish(state.workflow.id, event)
        apply_event(state, event)
      else
        state
      end

    {:noreply, maybe_finalize(state)}
  end

  def handle_info(:shutdown, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, %{status: state.status, workflow: state.workflow}}, state}
  end

  @impl true
  def handle_cast(:cancel, %{status: s} = state) when s in [:succeeded, :failed, :cancelled] do
    {:noreply, state}
  end

  def handle_cast(:cancel, state) do
    Atlas.Log.info("workflow:#{state.workflow.id}", "cancellation requested")
    Enum.each(state.step_servers, fn {_id, pid} -> GenServer.cast(pid, :cancel) end)
    {:noreply, state}
  end

  # --- internals ---

  defp depends_on_ids(deps) do
    Enum.map(deps, fn
      id when is_binary(id) -> id
      {id, status} when is_binary(id) and status in [:succeeded, :failed] -> id
    end)
  end

  defp apply_event(state, %Event{name: name, data: data}) do
    wf_id = state.workflow.id

    case name do
      ["workflow", ^wf_id, "step", step_id, lifecycle]
      when lifecycle in ["finished", "failed", "skipped", "cancelled"] ->
        new_status = lifecycle_to_status(lifecycle)

        {output, errors} =
          case {lifecycle, data} do
            {"finished", %{output: o}} -> {o, nil}
            {"failed", %{output: o, errors: e}} -> {o, e}
            _ -> {nil, nil}
          end

        %{
          state
          | step_statuses: Map.put(state.step_statuses, step_id, new_status),
            step_outputs: maybe_put(state.step_outputs, step_id, output),
            step_errors: maybe_put(state.step_errors, step_id, errors),
            updated_at: DateTime.utc_now()
        }

      _ ->
        state
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp lifecycle_to_status("finished"), do: :succeeded
  defp lifecycle_to_status("failed"), do: :failed
  defp lifecycle_to_status("skipped"), do: :skipped
  defp lifecycle_to_status("cancelled"), do: :cancelled

  defp maybe_finalize(%{status: s} = state) when s in [:succeeded, :failed, :cancelled], do: state

  defp maybe_finalize(state) do
    if Enum.all?(state.step_statuses, fn {_id, s} ->
         s in [:succeeded, :failed, :skipped, :cancelled]
       end) do
      finalize(state)
    else
      state
    end
  end

  defp finalize(state) do
    failed? = Enum.any?(state.step_statuses, fn {_id, s} -> s in [:failed, :cancelled] end)
    cancelled_any? = Enum.any?(state.step_statuses, fn {_id, s} -> s == :cancelled end)

    status =
      cond do
        cancelled_any? -> :cancelled
        failed? -> :failed
        true -> :succeeded
      end

    workflow = %{state.workflow | output: state.step_outputs, errors: collect_errors(state)}

    state = %{
      state
      | status: status,
        workflow: workflow,
        finished_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
    }

    log_finalize(status, state.workflow.id, state.step_statuses)
    PubSub.publish(state.workflow.id, Event.workflow_finished(state.workflow.id, status))
    Process.send_after(self(), :shutdown, @final_ttl_ms)
    state
  end

  defp log_finalize(:succeeded, wf_id, _step_statuses) do
    Atlas.Log.info("workflow:#{wf_id}", "succeeded")
  end

  defp log_finalize(:failed, wf_id, step_statuses) do
    failed = for {id, s} <- step_statuses, s in [:failed, :cancelled], do: id
    Atlas.Log.error("workflow:#{wf_id}", "failed (steps: #{Enum.join(failed, ", ")})")
  end

  defp log_finalize(:cancelled, wf_id, _step_statuses) do
    Atlas.Log.warn("workflow:#{wf_id}", "cancelled")
  end

  defp collect_errors(state) do
    for step <- state.workflow.steps,
        Map.get(state.step_statuses, step.id) in [:failed, :cancelled],
        into: %{} do
      {step.id, Map.get(state.step_errors, step.id, [])}
    end
  end
end
