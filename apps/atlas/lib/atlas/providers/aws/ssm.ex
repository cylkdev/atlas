defmodule Atlas.Providers.AWS.SSM do
  @moduledoc """
  General-purpose workflow provider for AWS Systems Manager. The
  `:action` argument selects the behaviour; each action has its own
  argument set.

  ## Action: `:wait`

  Polls `AWS.EC2.describe_instances/1` for running instances tagged
  `ReleaseGroup=<release_group>` / `ReleaseEnvironment=<release_environment>`
  and `AWS.SSM.describe_instance_information/1` for each instance's
  `ping_status`. Returns once at least one matching instance exists
  **and** every currently-listed instance reports
  `ping_status: "Online"`.

  Designed to run in parallel with the terraform step that provisions
  the ASG: the EC2 query will initially return zero results, which the
  loop treats as "still waiting" within the shared
  `max_attempts × poll_interval_ms` budget.

  Mirrors the core polling behaviour of
  `cylk_platform/deploy/ansible/scripts/wait-for-ssm.sh`. The bash
  script's full diagnostic dump (VPC endpoints, private route tables,
  EC2 console output) is not replicated here — those APIs are not yet
  exposed by the `:aws` dependency. On timeout the provider logs the
  failing instances' SSM records and the security groups for their VPC.

  Required arguments:
    * `:action` (`:wait`).
    * `:release_environment` (string) — value of the `ReleaseEnvironment` tag
      to filter on (`$1` in the bash script).
    * `:since` (`DateTime.t()`) — only count instances whose `launch_time`
      is strictly later than this. Set by the caller to a moment captured
      before terraform begins so pre-existing instances from a prior
      deploy are ignored.

  Optional arguments:
    * `:region` (string, default `"us-east-1"`).
    * `:release_group` (string, default `"cylk"`) — value of the
      `ReleaseGroup` tag.
    * `:max_attempts` (pos integer, default `30`).
    * `:poll_interval_ms` (pos integer, default `10_000`).

  Return values:
    * Success → `{:ok, %{instance_ids: [String.t()]}}`.
    * Budget exhausted →
      `{:error, %{reason: :timeout, attempts: n, online: [ids],
       pending: [ids]}, [{:timeout_ms, total}]}`.
    * `describe-instances` failed →
      `{:error, %{reason: :describe_instances_failed, error: term}}`.
    * Cancelled → `{:error, :cancelled}`.
    * Missing required arg → `{:error, {:missing_argument, key}}`.
    * Unknown action → `{:error, {:invalid_action, action}}`.

  The Task running this provider also responds to a `:cancel` message
  between poll attempts, mirroring
  `apps/atlas/lib/atlas/workflows/providers/aws/auto_scaling.ex`.
  """

  @behaviour Atlas.Workflow.Step.Provider

  @default_region "us-east-1"
  @default_release_group "cylk"
  @default_max_attempts 30
  @default_poll_interval_ms 10_000

  @impl true
  def call(arguments, _data, ctx) do
    with {:ok, action} <- fetch(arguments, :action),
         :ok <- validate_action(action) do
      dispatch(action, arguments, ctx)
    end
  end

  defp validate_action(:wait), do: :ok
  defp validate_action(other), do: {:error, {:invalid_action, other}}

  defp dispatch(:wait, arguments, ctx) do
    with {:ok, release_environment} <- fetch(arguments, :release_environment),
         {:ok, since} <- fetch(arguments, :since) do
      opts = %{
        release_environment: release_environment,
        since: since,
        region: Map.get(arguments, :region, @default_region),
        release_group: Map.get(arguments, :release_group, @default_release_group),
        max_attempts: Map.get(arguments, :max_attempts, @default_max_attempts),
        poll_interval_ms: Map.get(arguments, :poll_interval_ms, @default_poll_interval_ms)
      }

      Atlas.Log.info(
        log_id(ctx),
        "waiting for SSM online tag:ReleaseGroup=#{opts.release_group} " <>
          "tag:ReleaseEnvironment=#{opts.release_environment} " <>
          "since=#{DateTime.to_iso8601(opts.since)} " <>
          "(budget #{opts.max_attempts}×#{opts.poll_interval_ms}ms)"
      )

      poll(%{}, MapSet.new(), 0, opts, ctx)
    end
  end

  # Budget exhausted.
  defp poll(known, online, attempts, %{max_attempts: max} = opts, ctx)
       when attempts >= max do
    total_ms = max * opts.poll_interval_ms
    discovered = Map.keys(known)
    pending = discovered |> Enum.reject(&MapSet.member?(online, &1))

    Atlas.Log.error(
      log_id(ctx),
      "timed out after #{total_ms}ms — discovered=#{inspect(discovered)} " <>
        "online=#{inspect(MapSet.to_list(online))} pending=#{inspect(pending)}"
    )

    Enum.each(pending, fn id -> dump_diagnostics(Map.fetch!(known, id), opts, ctx) end)

    {:error,
     %{
       reason: :timeout,
       attempts: attempts,
       online: MapSet.to_list(online),
       pending: pending
     }, [{:timeout_ms, total_ms}]}
  end

  defp poll(known, online, attempts, opts, ctx) do
    receive do
      :cancel ->
        Atlas.Log.warn(log_id(ctx), "cancel signal received, exiting waiter")
        {:error, :cancelled}
    after
      0 ->
        case describe_target_instances(opts) do
          {:ok, instances} ->
            handle_instances(instances, known, online, attempts, opts, ctx)

          {:error, _} = err ->
            err
        end
    end
  end

  defp handle_instances([], known, online, attempts, opts, ctx) do
    Atlas.Log.info(
      log_id(ctx),
      "no matching instances yet (attempt #{attempts + 1}/#{opts.max_attempts})"
    )

    sleep_then_poll(known, online, attempts, opts, ctx)
  end

  defp handle_instances(instances, known, online, attempts, opts, ctx) do
    known = Enum.reduce(instances, known, &Map.put(&2, &1.instance_id, &1))
    current_ids = Enum.map(instances, & &1.instance_id) |> MapSet.new()
    pending = MapSet.difference(current_ids, online)

    new_online =
      Enum.reduce(pending, online, fn id, acc ->
        case ping_status(id, opts) do
          "Online" ->
            Atlas.Log.info(log_id(ctx), "#{id} is Online")
            MapSet.put(acc, id)

          other ->
            Atlas.Log.info(
              log_id(ctx),
              "#{id} not yet online (attempt #{attempts + 1}/#{opts.max_attempts}) " <>
                "status=#{inspect(other)}"
            )

            acc
        end
      end)

    if MapSet.equal?(current_ids, new_online) do
      ids = MapSet.to_list(current_ids)
      Atlas.Log.info(log_id(ctx), "all #{length(ids)} instance(s) Online: #{Enum.join(ids, ",")}")
      {:ok, %{instance_ids: ids}}
    else
      sleep_then_poll(known, new_online, attempts, opts, ctx)
    end
  end

  defp sleep_then_poll(known, online, attempts, opts, ctx) do
    receive do
      :cancel ->
        Atlas.Log.warn(log_id(ctx), "cancel signal received, exiting waiter")
        {:error, :cancelled}
    after
      opts.poll_interval_ms ->
        poll(known, online, attempts + 1, opts, ctx)
    end
  end

  defp describe_target_instances(opts) do
    case AWS.EC2.describe_instances(
           region: opts.region,
           filters: [
             %{name: "tag:ReleaseGroup", values: [opts.release_group]},
             %{name: "tag:ReleaseEnvironment", values: [opts.release_environment]},
             %{name: "instance-state-name", values: ["running"]}
           ]
         ) do
      {:ok, %{reservations: reservations}} ->
        instances =
          for reservation <- reservations,
              instance <- reservation.instances,
              launched_after?(instance, opts.since),
              do: instance

        {:ok, instances}

      {:error, error} ->
        {:error, %{reason: :describe_instances_failed, error: error}}
    end
  end

  defp launched_after?(instance, %DateTime{} = since) do
    case instance |> Map.get(:launch_time) |> to_datetime() do
      %DateTime{} = launch_time -> DateTime.compare(launch_time, since) == :gt
      nil -> false
    end
  end

  defp to_datetime(%DateTime{} = dt), do: dt

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp to_datetime(_), do: nil

  defp ping_status(id, opts) do
    case AWS.SSM.describe_instance_information(
           region: opts.region,
           filters: [%{"Key" => "InstanceIds", "Values" => [id]}]
         ) do
      {:ok, %{instance_information_list: [%{ping_status: status} | _]}} ->
        status

      _ ->
        nil
    end
  end

  defp dump_diagnostics(instance, opts, ctx) do
    Atlas.Log.error(log_id(ctx), "DIAGNOSTICS for instance #{instance.instance_id}")

    Atlas.Log.error(
      log_id(ctx),
      "vpc=#{Map.get(instance, :vpc_id, "None")} " <>
        "subnet=#{Map.get(instance, :subnet_id, "None")}"
    )

    log_call(log_id(ctx), "ssm:describe_instance_information", fn ->
      AWS.SSM.describe_instance_information(
        region: opts.region,
        filters: [%{"Key" => "InstanceIds", "Values" => [instance.instance_id]}]
      )
    end)

    case Map.get(instance, :vpc_id) do
      vpc_id when is_binary(vpc_id) and vpc_id != "" ->
        log_call(log_id(ctx), "ec2:describe_security_groups vpc=#{vpc_id}", fn ->
          AWS.EC2.describe_security_groups(
            region: opts.region,
            filters: [%{name: "vpc-id", values: [vpc_id]}]
          )
        end)

      _ ->
        :ok
    end
  end

  defp log_call(log_id, label, func) do
    Atlas.Log.error(log_id, "#{label} → #{inspect(func.(), pretty: true, limit: :infinity)}")
  end

  defp log_id(ctx), do: "workflow:#{ctx.workflow_id}:#{ctx.step_id}"

  defp fetch(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_argument, key}}
    end
  end
end
