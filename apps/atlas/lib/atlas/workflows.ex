defmodule Atlas.Workflows do
  @moduledoc """
  Public facade for the Atlas workflow runtime.

  ## End-to-end use

      wf = %Atlas.Workflow{
        steps: [
          %Atlas.Workflow.Step{
            id: "tf",
            provider: Atlas.Providers.Terraform,
            arguments: %{action: :apply, working_directory: "/infra"}
          },
          %Atlas.Workflow.Step{
            id: "configure",
            provider: Atlas.Providers.Ansible,
            arguments: %{playbook: "/infra/configure.yml"},
            subscribe_to: [["terraform", "aws_autoscaling_group", "created", "*"]]
          }
        ]
      }

      {:ok, final} = Atlas.Workflows.run(wf, await: true)

  `configure` does not declare `depends_on: ["tf"]`. It runs
  concurrently with `tf` and subscribes to the autoscaling-group
  `:created` event. Its provider starts as soon as one matching
  event has been received. Any further matching events are forwarded
  live to the ansible Task's mailbox while it runs.

  ## Subscribing externally

      Atlas.Workflows.subscribe(workflow_id, ["terraform", "*"])
      # receive {:workflow_event,
      #   %Event{name: ["workflow", "wf-...", "terraform", "aws_instance", "created", "web"],
      #          data: %{...}}}
  """

  alias Atlas.Workflow
  alias Atlas.Workflows.Orchestrator

  @registry Atlas.Workflows.Registry
  @orchestrator_supervisor Atlas.Workflows.OrchestratorSupervisor

  @spec run(Workflow.t()) :: {:ok, String.t()} | {:error, term()}
  def run(workflow), do: run(workflow, [])

  @spec run(Workflow.t(), keyword()) ::
          {:ok, String.t()} | {:ok, Workflow.t()} | {:error, term()}
  def run(%Workflow{} = workflow, opts) when is_list(opts) do
    await? = Keyword.get(opts, :await, false)
    await_timeout = Keyword.get(opts, :await_timeout, :infinity)
    workflow = %{workflow | id: workflow.id || Keyword.get(opts, :workflow_id) || generate_id()}

    Atlas.Log.info(
      "workflow:#{workflow.id}",
      "accepted with #{length(workflow.steps)} step(s)"
    )

    with :ok <- validate(workflow),
         :ok <- maybe_subscribe_for_await(workflow.id, await?),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(@orchestrator_supervisor, {Orchestrator, workflow}) do
      if await?, do: await_finished(workflow.id, await_timeout), else: {:ok, workflow.id}
    end
  end

  @spec status(String.t()) ::
          {:ok, %{status: atom(), workflow: Workflow.t()}} | {:error, :not_found}
  def status(workflow_id) when is_binary(workflow_id) do
    with {:ok, pid} <- lookup(workflow_id), do: GenServer.call(pid, :status)
  end

  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(workflow_id) when is_binary(workflow_id) do
    with {:ok, pid} <- lookup(workflow_id), do: GenServer.cast(pid, :cancel)
  end

  @doc """
  Subscribe to events in `workflow_id` whose name matches `pattern`.

  `pattern` is a list of string segments (relative to
  `["workflow", workflow_id]`). The string `"*"` matches one or more
  name segments. The caller can register multiple patterns by
  calling `subscribe/2` multiple times. Thin wrapper around
  `Atlas.Workflows.PubSub.subscribe/2`.
  """
  @spec subscribe(String.t(), [String.t()]) :: :ok
  def subscribe(workflow_id, pattern)
      when is_binary(workflow_id) and is_list(pattern) do
    Atlas.Workflows.PubSub.subscribe(workflow_id, pattern)
  end

  @spec unsubscribe(String.t(), [String.t()]) :: :ok
  def unsubscribe(workflow_id, pattern)
      when is_binary(workflow_id) and is_list(pattern) do
    Atlas.Workflows.PubSub.unsubscribe(workflow_id, pattern)
  end

  # --- internals ---

  defp lookup(workflow_id) do
    case Registry.lookup(@registry, {:orchestrator, workflow_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp maybe_subscribe_for_await(_workflow_id, false), do: :ok

  defp maybe_subscribe_for_await(workflow_id, true) do
    Atlas.Workflows.PubSub.subscribe(workflow_id, ["finished"])
  end

  defp await_finished(workflow_id, timeout) do
    receive do
      {:workflow_event, %Atlas.Workflows.Event{name: ["workflow", ^workflow_id, "finished"]}} ->
        result =
          case status(workflow_id) do
            {:ok, %{workflow: workflow}} -> {:ok, workflow}
            {:error, :not_found} -> {:error, :not_found}
          end

        Atlas.Workflows.PubSub.unsubscribe(workflow_id, ["finished"])
        result
    after
      timeout ->
        Atlas.Log.warn("workflow:#{workflow_id}", "await timed out after #{timeout}ms")
        Atlas.Workflows.PubSub.unsubscribe(workflow_id, ["finished"])
        {:error, :timeout}
    end
  end

  defp generate_id do
    "wf-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp validate(%Workflow{steps: steps}) do
    with :ok <- validate_ids(steps),
         :ok <- validate_dep_shapes(steps),
         :ok <- validate_dep_references(steps),
         :ok <- validate_subscriptions(steps),
         :ok <- validate_acyclic(steps) do
      :ok
    end
  end

  defp validate_ids(steps) do
    ids = Enum.map(steps, & &1.id)

    cond do
      Enum.any?(ids, fn id -> not is_binary(id) or id == "" end) ->
        {:error, :invalid_step_id}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, :duplicate_step_ids}

      true ->
        :ok
    end
  end

  defp validate_dep_shapes(steps) do
    bad =
      for step <- steps,
          dep <- step.depends_on,
          not valid_dep_shape?(dep),
          do: {step.id, dep}

    if bad == [], do: :ok, else: {:error, {:invalid_dependency_shape, bad}}
  end

  defp valid_dep_shape?(id) when is_binary(id), do: true
  defp valid_dep_shape?({id, s}) when is_binary(id) and s in [:succeeded, :failed], do: true
  defp valid_dep_shape?(_), do: false

  defp validate_dep_references(steps) do
    known = MapSet.new(steps, & &1.id)

    bad =
      for step <- steps,
          dep <- step.depends_on,
          not MapSet.member?(known, dep_ref(dep)),
          do: {step.id, dep}

    if bad == [], do: :ok, else: {:error, {:dangling_dependencies, bad}}
  end

  defp validate_subscriptions(steps) do
    bad =
      for step <- steps,
          pattern <- step.subscribe_to,
          not valid_pattern?(pattern),
          do: {step.id, pattern}

    if bad == [], do: :ok, else: {:error, {:invalid_subscription_pattern, bad}}
  end

  defp valid_pattern?(pattern) when is_list(pattern) and pattern != [] do
    Enum.all?(pattern, fn seg -> is_binary(seg) and seg != "" end)
  end

  defp valid_pattern?(_), do: false

  defp dep_ref(id) when is_binary(id), do: id
  defp dep_ref({id, _}), do: id

  defp validate_acyclic(steps) do
    graph =
      Enum.into(steps, %{}, fn step -> {step.id, Enum.map(step.depends_on, &dep_ref/1)} end)

    case topo_sort(graph) do
      {:ok, _} -> :ok
      :error -> {:error, :cycle_detected}
    end
  end

  defp topo_sort(graph), do: do_topo(graph, [])
  defp do_topo(graph, acc) when graph == %{}, do: {:ok, Enum.reverse(acc)}

  defp do_topo(graph, acc) do
    case Enum.find(graph, fn {_id, deps} -> deps == [] end) do
      nil ->
        :error

      {id, _} ->
        graph
        |> Map.delete(id)
        |> Enum.into(%{}, fn {k, deps} -> {k, List.delete(deps, id)} end)
        |> do_topo([id | acc])
    end
  end
end
