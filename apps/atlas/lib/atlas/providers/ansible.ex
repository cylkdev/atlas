defmodule Atlas.Providers.Ansible do
  @moduledoc """
  Provider that runs an Ansible playbook via the same
  `Atlas.Workflows.OsCommand` (`:erlexec`/`ElixirExec`) helper used
  by the old workflow plugins. Runs with `ANSIBLE_STDOUT_CALLBACK=json`
  so the entire run produces one JSON document; lines are accumulated
  in a buffer and decoded on exit. One
  `Atlas.Workflows.Events.ansible_task` event is emitted per task per
  host (in declaration order) and forwarded to the step server.

  Both stdout and stderr are buffered. On a non-zero exit the raw stdout
  and stderr are logged, so failures that never become a parseable task
  event — inventory parse errors, connection/unreachable diagnostics,
  fatals emitted outside the JSON document — are still visible.

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
            consume(new_state, prepend_lines(acc, lines), ctx)

          {:exit, 0, tails, _new_state} ->
            lines = Enum.reverse(acc) ++ tails
            emit_task_events(stdout_text(lines), ctx)
            Atlas.Log.info(log_id(ctx), "ansible-playbook succeeded")
            {:ok, %{exit_status: 0}}

          {:exit, status, tails, _new_state} ->
            lines = Enum.reverse(acc) ++ tails
            emit_task_events(stdout_text(lines), ctx)
            Atlas.Log.error(log_id(ctx), "ansible-playbook exited #{status}")
            log_failure_output(lines, ctx)
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

  # Accumulate stdout AND stderr (tagged), newest first. The JSON callback
  # writes to stdout; stderr carries the failures the callback never sees
  # (inventory parse errors, connection/unreachable diagnostics, fatals).
  defp prepend_lines(acc, lines), do: Enum.reduce(lines, acc, fn line, list -> [line | list] end)

  defp stdout_text(lines), do: for({:stdout, line} <- lines, do: line) |> Enum.join("\n")
  defp stderr_text(lines), do: for({:stderr, line} <- lines, do: line) |> Enum.join("\n")

  # On a non-zero exit, surface the raw output so the actual error is
  # visible even when it never made it into a parseable task event.
  defp log_failure_output(lines, ctx) do
    err = stderr_text(lines)
    if err != "", do: Atlas.Log.error(log_id(ctx), "ansible-playbook stderr:\n#{tail(err)}")

    out = stdout_text(lines)
    if out != "", do: Atlas.Log.error(log_id(ctx), "ansible-playbook stdout:\n#{tail(out)}")
  end

  @max_log_bytes 8_000
  defp tail(text) when byte_size(text) > @max_log_bytes do
    "…(truncated, last #{@max_log_bytes} bytes)…\n" <>
      binary_part(text, byte_size(text) - @max_log_bytes, @max_log_bytes)
  end

  defp tail(text), do: text

  defp emit_task_events(output, ctx) do
    case JSON.decode(output) do
      {:ok, %{"plays" => plays}} ->
        Enum.each(plays, fn play ->
          play_name = get_in(play, ["play", "name"])

          Enum.each(Map.get(play, "tasks", []), fn task ->
            task_name = get_in(task, ["task", "name"])

            Enum.each(Map.get(task, "hosts", %{}), fn {host, host_result} ->
              status = classify(host_result)
              log_task(status, log_id(ctx), play_name, task_name, host, host_result)

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

  defp log_task(:failed, id, play, task, host, result) do
    Atlas.Log.error(id, "[#{play}] #{task} on #{host}: failed — #{result_msg(result)}")
  end

  defp log_task(:unreachable, id, play, task, host, result) do
    Atlas.Log.error(id, "[#{play}] #{task} on #{host}: unreachable — #{result_msg(result)}")
  end

  defp log_task(status, id, play, task, host, _result) when status in [:ok, :changed, :skipped] do
    Atlas.Log.info(id, "[#{play}] #{task} on #{host}: #{status}")
  end

  defp result_msg(%{"msg" => msg}) when is_binary(msg) and msg != "", do: msg
  defp result_msg(%{"stderr" => err}) when is_binary(err) and err != "", do: err
  defp result_msg(result), do: inspect(result, limit: 20)

  defp classify(%{"failed" => true}), do: :failed
  defp classify(%{"unreachable" => true}), do: :unreachable
  defp classify(%{"skipped" => true}), do: :skipped
  defp classify(%{"changed" => true}), do: :changed
  defp classify(_), do: :ok
end
