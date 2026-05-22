defmodule Atlas.Providers.Ansible do
  @moduledoc """
  Provider that runs an Ansible playbook via the same
  `Atlas.Workflows.OsCommand` (`:erlexec`/`ElixirExec`) helper used
  by the old workflow plugins. Runs with `ANSIBLE_STDOUT_CALLBACK=json`
  so the entire run produces one JSON document; lines are accumulated
  in a buffer and decoded on exit. One
  `Atlas.Workflows.Events.ansible_task` event is emitted per task per
  host (in declaration order) and forwarded to the step server.

  Required arguments:
    * `:playbook` (string).

  Optional arguments:
    * `:inventory` (string).
    * `:extra_vars` (map of `binary => binary`).
    * `:working_directory` (string).
    * `:env` (map of `binary => binary`).
    * `:binary` (string, default `"ansible-playbook"`).

  The Task running this provider also responds to a `:cancel` message:
  on receipt it calls `OsCommand.cancel/1`, drains remaining
  `:erlexec` messages, and returns `{:error, :cancelled}`.
  """

  @behaviour Atlas.Workflow.Step.Provider

  alias Atlas.Workflows.Event
  alias Atlas.Workflows.OsCommand
  alias Atlas.Workflows.PubSub

  @impl true
  def call(arguments, _data, ctx) do
    with {:ok, playbook} <- fetch(arguments, :playbook) do
      config = %{
        executable: Map.get(arguments, :binary, "ansible-playbook"),
        arguments: build_argv(playbook, arguments),
        cwd: Map.get(arguments, :working_directory, "."),
        env: Map.merge(Map.get(arguments, :env, %{}), %{"ANSIBLE_STDOUT_CALLBACK" => "json"})
      }

      Atlas.Log.info(
        log_id(ctx),
        "running `#{config.executable} #{Enum.join(config.arguments, " ")}` in #{config.cwd}"
      )

      case OsCommand.start(config) do
        {:ok, state} ->
          consume(state, [], ctx)

        {:error, reason} ->
          Atlas.Log.error(log_id(ctx), "failed to start ansible-playbook: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp log_id(ctx), do: "workflow:#{ctx.workflow_id}:#{ctx.step_id}"

  defp fetch(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_argument, key}}
    end
  end

  defp build_argv(playbook, arguments) do
    base = [playbook]
    base = if inv = Map.get(arguments, :inventory), do: base ++ ["-i", inv], else: base

    vars =
      arguments
      |> Map.get(:extra_vars, %{})
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
      |> Enum.join(" ")

    if vars == "", do: base, else: base ++ ["--extra-vars", vars]
  end

  defp consume(state, acc, ctx) do
    receive do
      :cancel ->
        Atlas.Log.warn(log_id(ctx), "cancel signal received, sending SIGTERM to ansible-playbook")
        OsCommand.cancel(state)
        drain(state)
        {:error, :cancelled}

      msg ->
        case OsCommand.handle_message(msg, state) do
          {:lines, lines, new_state} ->
            consume(new_state, append_stdout(acc, lines), ctx)

          {:exit, 0, tails, _new_state} ->
            output = collect_output(acc, tails)
            emit_task_events(output, ctx)
            Atlas.Log.info(log_id(ctx), "ansible-playbook succeeded")
            {:ok, %{exit_status: 0}}

          {:exit, status, tails, _new_state} ->
            output = collect_output(acc, tails)
            emit_task_events(output, ctx)
            Atlas.Log.error(log_id(ctx), "ansible-playbook exited #{status}")
            {:error, %{exit_status: status}, []}

          {:noop, new_state} ->
            consume(new_state, acc, ctx)
        end
    end
  end

  defp drain(state) do
    receive do
      msg ->
        case OsCommand.handle_message(msg, state) do
          {:exit, _, _, _} -> :ok
          {:lines, _, new_state} -> drain(new_state)
          {:noop, new_state} -> drain(new_state)
        end
    after
      5_000 -> :ok
    end
  end

  defp append_stdout(acc, lines) do
    Enum.reduce(lines, acc, fn
      {:stdout, line}, list -> [line | list]
      _, list -> list
    end)
  end

  defp collect_output(acc, tails) do
    tail_lines = for {:stdout, line} <- tails, do: line
    (Enum.reverse(acc) ++ tail_lines) |> Enum.join("\n")
  end

  defp emit_task_events(output, ctx) do
    case JSON.decode(output) do
      {:ok, %{"plays" => plays}} ->
        Enum.each(plays, fn play ->
          play_name = get_in(play, ["play", "name"])

          Enum.each(Map.get(play, "tasks", []), fn task ->
            task_name = get_in(task, ["task", "name"])

            Enum.each(Map.get(task, "hosts", %{}), fn {host, host_result} ->
              status = classify(host_result)
              log_task(status, log_id(ctx), play_name, task_name, host)

              event =
                Event.ansible_task(
                  ctx.workflow_id,
                  status,
                  task_name,
                  host,
                  %{play: play_name, raw: host_result}
                )

              PubSub.publish(ctx.workflow_id, event)
            end)
          end)
        end)

      _ ->
        :ok
    end
  end

  defp log_task(:failed, id, play, task, host) do
    Atlas.Log.error(id, "[#{play}] #{task} on #{host}: failed")
  end

  defp log_task(:unreachable, id, play, task, host) do
    Atlas.Log.error(id, "[#{play}] #{task} on #{host}: unreachable")
  end

  defp log_task(status, id, play, task, host) when status in [:ok, :changed, :skipped] do
    Atlas.Log.info(id, "[#{play}] #{task} on #{host}: #{status}")
  end

  defp classify(%{"failed" => true}), do: :failed
  defp classify(%{"unreachable" => true}), do: :unreachable
  defp classify(%{"skipped" => true}), do: :skipped
  defp classify(%{"changed" => true}), do: :changed
  defp classify(_), do: :ok
end
