defmodule Atlas.Workflow.Step.Server do
  @moduledoc """
  One GenServer per step.

  In `init/1` the server subscribes through `Atlas.Workflows.PubSub`
  to two kinds of topics: (a) one `["step", dep_id, "*"]` pattern per
  entry in `depends_on`, and (b) every pattern declared in
  `subscribe_to`. From the moment the server is alive it receives
  `{:workflow_event, %Event{}}` messages in its mailbox.

  Events are **not** buffered. On every incoming event:

    * If `event.name` has the shape
      `["workflow", workflow_id, "step", dep_id, lifecycle]` and
      `dep_id` is in this step's `depends_on`, the server updates its
      `dep_statuses` map (and merges `event.data.value` into its
      `data` map on `"finished"`).
    * If the event matches any of this step's `subscribe_to` patterns,
      the server marks each such pattern satisfied (boolean only — no
      event content is stored) by removing it from
      `unmatched_subscriptions`, and — if the provider Task is
      already running — forwards the event to the Task's mailbox so
      the provider can `receive` it.

  When every dependency is terminal AND `unmatched_subscriptions == []`
  AND `depends_on` predicates all match expected status, the server
  spawns its provider as a `Task.Supervisor.async_nolink/3`.

  Providers publish their own events by calling
  `Atlas.Workflows.PubSub.publish(ctx.workflow_id, event)` directly.
  The step server's lifecycle events (`:started` / `:finished` /
  `:failed` / `:skipped` / `:retrying` / `:cancelled`) are built
  using named functions on `Atlas.Workflows.Event` and published the
  same way (`PubSub.publish/2`).

  Cancellation funnels through `terminate/2`. `handle_cast(:cancel, _)`
  only triggers `{:stop, {:shutdown, :cancelled}, state}`; the
  `terminate({:shutdown, :cancelled}, state)` callback is the one
  place that sends `:cancel` to the provider Task, cancels the
  timeout timer, and publishes `Event.step_cancelled/2`. Every other
  stop reason has already cleared task state and emitted its terminal
  event before returning `{:stop, :normal, _}`, so `terminate(_, _)`
  is a no-op in those paths.

  Internal helpers (`evaluate/1`, `finish_attempt/2`) return
  `{:cont, state}` or `{:stop, state}`; the matching `handle_info/2`
  clause threads that through `reply/1`.
  """

  use GenServer

  alias Atlas.Workflow.Step
  alias Atlas.Workflows.Event
  alias Atlas.Workflows.Event.Pattern
  alias Atlas.Workflows.PubSub

  @task_supervisor Atlas.Workflows.TaskSupervisor

  @type init_args :: %{
          step: Step.t(),
          workflow_id: String.t(),
          orchestrator: pid(),
          depends_on_ids: [String.t()]
        }

  def start_link(init_args), do: GenServer.start_link(__MODULE__, init_args)

  @impl true
  def init(%{step: %Step{} = step} = args) do
    dep_statuses = Map.new(args.depends_on_ids, fn id -> {id, :pending} end)

    # Subscribe to every dep's step-lifecycle topic.
    Enum.each(args.depends_on_ids, fn dep_id ->
      :ok = PubSub.subscribe(args.workflow_id, ["step", dep_id, "*"])
    end)

    # Subscribe to every user-declared pattern.
    Enum.each(step.subscribe_to, fn pattern ->
      :ok = PubSub.subscribe(args.workflow_id, pattern)
    end)

    compiled_subs = Enum.map(step.subscribe_to, &Pattern.compile(&1, args.workflow_id))

    state = %{
      step: step,
      workflow_id: args.workflow_id,
      orchestrator: args.orchestrator,
      status: :pending,
      data: %{},
      dep_statuses: dep_statuses,
      subscribe_to: compiled_subs,
      unmatched_subscriptions: compiled_subs,
      task_ref: nil,
      task_pid: nil,
      attempt: 0,
      timeout_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:go, state) do
    reply(evaluate(state))
  end

  def handle_info({:workflow_event, %Event{} = event}, state) do
    # 1. Forward matching events to the running Task (if any) so the
    #    provider can react live. Done first so it happens whether the
    #    step is still gating or already running its provider.
    if state.task_pid && subscription_match?(state, event) do
      send(state.task_pid, {:workflow_event, event})
    end

    # 2. State machinery for gating + dep tracking, only while pending.
    if state.status == :pending do
      state = ingest_step_event(state, event)
      state = ingest_subscription_event(state, event)
      reply(evaluate(state))
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    cancel_timeout(state)
    state = %{state | task_ref: nil, task_pid: nil, timeout_ref: nil}
    reply(finish_attempt(state, result))
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    cancel_timeout(state)
    state = %{state | task_ref: nil, task_pid: nil, timeout_ref: nil}
    reply(finish_attempt(state, {:error, {:task_down, reason}}))
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:retry, attempt}, %{attempt: prev} = state) when attempt == prev + 1 do
    {:noreply, run_provider(state, attempt)}
  end

  def handle_info({:retry, _attempt}, state) do
    {:noreply, state}
  end

  def handle_info({:timeout, attempt}, %{attempt: attempt, task_pid: pid, task_ref: ref} = state)
      when is_pid(pid) and is_reference(ref) do
    # Same protocol as `:cancel`: ask the provider to wind down its
    # OS process via `OsCommand.cancel/1`; ignore the eventual
    # `{ref, result}`.
    send(pid, :cancel)
    Process.demonitor(ref, [:flush])
    state = %{state | task_ref: nil, task_pid: nil, timeout_ref: nil}
    reply(finish_attempt(state, {:error, :timeout}))
  end

  def handle_info({:timeout, _attempt}, state) do
    {:noreply, state}
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast(:cancel, %{status: s} = state)
      when s in [:succeeded, :failed, :skipped, :cancelled] do
    {:noreply, state}
  end

  def handle_cast(:cancel, state) do
    {:stop, {:shutdown, :cancelled}, state}
  end

  @impl true
  def terminate({:shutdown, :cancelled}, state) do
    # Single place that handles cancellation cleanup: tell the
    # provider Task to wind down its OS process (via
    # `OsCommand.cancel/1`), cancel the timeout timer, and publish
    # the step's cancelled event.
    Atlas.Log.warn("workflow:#{state.workflow_id}:#{state.step.id}", "cancelled")
    if state.task_pid, do: send(state.task_pid, :cancel)
    cancel_timeout(state)
    PubSub.publish(state.workflow_id, Event.step_cancelled(state.workflow_id, state.step.id))
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- internals ---

  defp reply({:cont, state}), do: {:noreply, state}
  defp reply({:stop, state}), do: {:stop, :normal, state}

  defp ingest_step_event(state, %Event{name: name, data: data}) do
    wf_id = state.workflow_id
    own_id = state.step.id

    case name do
      ["workflow", ^wf_id, "step", dep_id, lifecycle]
      when dep_id != own_id and lifecycle in ["finished", "failed", "skipped", "cancelled"] ->
        if Map.has_key?(state.dep_statuses, dep_id) do
          new_status = lifecycle_to_status(lifecycle)

          data_map =
            case {lifecycle, data} do
              {"finished", %{output: output}} -> Map.put(state.data, dep_id, output)
              _ -> state.data
            end

          %{state | dep_statuses: Map.put(state.dep_statuses, dep_id, new_status), data: data_map}
        else
          state
        end

      _ ->
        state
    end
  end

  defp lifecycle_to_status("finished"), do: :succeeded
  defp lifecycle_to_status("failed"), do: :failed
  defp lifecycle_to_status("skipped"), do: :skipped
  defp lifecycle_to_status("cancelled"), do: :cancelled

  defp ingest_subscription_event(%{unmatched_subscriptions: []} = state, _event), do: state

  defp ingest_subscription_event(state, %Event{name: name}) do
    remaining =
      Enum.reject(state.unmatched_subscriptions, fn p -> Pattern.matches?(p, name) end)

    %{state | unmatched_subscriptions: remaining}
  end

  defp subscription_match?(%{subscribe_to: []}, _event), do: false

  defp subscription_match?(state, %Event{name: name}) do
    Enum.any?(state.subscribe_to, fn p -> Pattern.matches?(p, name) end)
  end

  defp evaluate(state) do
    cond do
      state.status != :pending ->
        {:cont, state}

      Enum.any?(state.dep_statuses, fn {_id, s} -> s == :pending end) ->
        {:cont, state}

      not deps_match?(state) ->
        Atlas.Log.warn(
          "workflow:#{state.workflow_id}:#{state.step.id}",
          "skipped (upstream dep status did not match)"
        )

        PubSub.publish(state.workflow_id, Event.step_skipped(state.workflow_id, state.step.id))
        {:stop, %{state | status: :skipped}}

      state.unmatched_subscriptions != [] ->
        {:cont, state}

      true ->
        {:cont, run_provider(state, 1)}
    end
  end

  defp deps_match?(state) do
    Enum.all?(state.step.depends_on, fn dep ->
      {dep_id, expected} =
        case dep do
          id when is_binary(id) -> {id, :succeeded}
          {id, status} -> {id, status}
        end

      Map.get(state.dep_statuses, dep_id) == expected
    end)
  end

  defp run_provider(state, attempt) do
    ctx = %{
      workflow_id: state.workflow_id,
      step_id: state.step.id
    }

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        state.step.provider.call(state.step.arguments, state.data, ctx)
      end)

    timeout_ref =
      if is_integer(state.step.timeout) do
        Process.send_after(self(), {:timeout, attempt}, state.step.timeout)
      end

    if attempt == 1 do
      Atlas.Log.info(
        "workflow:#{state.workflow_id}:#{state.step.id}",
        "started (#{inspect(state.step.provider)})"
      )

      PubSub.publish(
        state.workflow_id,
        Event.step_started(state.workflow_id, state.step.id, attempt)
      )
    else
      Atlas.Log.info(
        "workflow:#{state.workflow_id}:#{state.step.id}",
        "retry attempt #{attempt}"
      )
    end

    %{
      state
      | status: :running,
        task_ref: task.ref,
        task_pid: task.pid,
        attempt: attempt,
        timeout_ref: timeout_ref
    }
  end

  defp finish_attempt(state, raw_result) do
    case classify(raw_result) do
      {:succeeded, output, _errors} ->
        Atlas.Log.info(
          "workflow:#{state.workflow_id}:#{state.step.id}",
          "succeeded (attempt #{state.attempt})"
        )

        PubSub.publish(
          state.workflow_id,
          Event.step_finished(state.workflow_id, state.step.id, output, state.attempt)
        )

        {:stop, %{state | status: :succeeded}}

      {:failed, output, errors} ->
        trigger = failure_trigger(output)

        if state.attempt <= state.step.retry.max and trigger in state.step.retry.on do
          delay = backoff_ms(state.step.retry.backoff, state.attempt)
          next = state.attempt + 1

          Atlas.Log.warn(
            "workflow:#{state.workflow_id}:#{state.step.id}",
            "attempt #{state.attempt} failed (#{inspect(trigger)}), retrying in #{delay}ms"
          )

          PubSub.publish(
            state.workflow_id,
            Event.step_retrying(
              state.workflow_id,
              state.step.id,
              state.attempt,
              next,
              output,
              delay
            )
          )

          Process.send_after(self(), {:retry, next}, delay)
          {:cont, %{state | status: :pending}}
        else
          Atlas.Log.error(
            "workflow:#{state.workflow_id}:#{state.step.id}",
            "failed after #{state.attempt} attempt(s) (#{inspect(trigger)})"
          )

          PubSub.publish(
            state.workflow_id,
            Event.step_failed(state.workflow_id, state.step.id, output, errors, state.attempt)
          )

          {:stop, %{state | status: :failed}}
        end
    end
  end

  defp cancel_timeout(%{timeout_ref: nil}), do: :ok

  defp cancel_timeout(%{timeout_ref: ref}) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp classify(:ok), do: {:succeeded, nil, []}
  defp classify({:ok, output}), do: {:succeeded, output, []}
  defp classify({:error, output}), do: {:failed, output, []}
  defp classify({:error, output, errors}) when is_list(errors), do: {:failed, output, errors}
  defp classify(other), do: {:failed, {:bad_return, other}, []}

  defp failure_trigger(:timeout), do: :timeout
  defp failure_trigger(%{exit_status: _}), do: :exit_status
  defp failure_trigger(_), do: :error

  defp backoff_ms(:none, _attempt), do: 0
  defp backoff_ms(:linear, attempt), do: attempt * 1_000
  defp backoff_ms(:exponential, attempt), do: trunc(:math.pow(2, attempt - 1) * 1_000)
  defp backoff_ms({:fixed, ms}, _attempt), do: ms
end
