defmodule Atlas.Providers.Terraform do
  @moduledoc """
  Provider that runs `terraform` with `-json` output via the same
  `Atlas.Workflows.OsCommand` (`:erlexec`/`ElixirExec`) helper used by
  the old workflow plugins. For each complete stdout line that decodes
  as JSON with a recognized `"type"`, the provider builds a
  `%Atlas.Workflows.Event{}` and publishes it via
  `Atlas.Workflows.PubSub.publish/2`.

  Required arguments:
    * `:action` (`:apply | :destroy | :init | :plan`)
    * `:working_directory` (string)

  Optional arguments:
    * `:vars` (map of `binary => binary`) — passed as `-var key=value`.
    * `:auto_approve` (boolean, default `true` for `:apply` / `:destroy`).
    * `:binary` (string, default `"terraform"`).
    * `:env` (map of `binary => binary`).
    * `:out` (string) — passed as `-out=<path>`. The path to write
      the binary plan artifact to (only meaningful for `:plan`). The
      `-json` stdout stream is unaffected.
    * `:plan` (string) — for `:apply`, applies a saved plan from
      the given path. The path is appended as a positional argument.
      When set, `-var-file`, `-var`, and `-auto-approve` are suppressed
      because terraform rejects them alongside a saved plan (variables
      and the approval are already baked into the plan file).
    * `:var_file` (string) — passed as `-var-file=<path>`. Loads
      variables from the given `.tfvars` file.

  Recognized terraform JSON `type` values:
    * `"planned_change"` → `:planned`
    * `"apply_start"`    → `:creating` / `:updating` / `:destroying`
                           based on the hook's `action` field
    * `"apply_complete"` → `:created` / `:updated` / `:destroyed`
    * `"apply_errored"`  → `:failed`
    * `"diagnostic"`     → published as
                           `["terraform", "diagnostic", severity]`
                           (`severity` is `"error"` or `"warning"`).

  All other lines are ignored.

  Return values:
    * Success → `{:ok, %{exit_status: 0, result: %{plan: path}}}`
      where `path` is whatever was passed in `:out` (or `nil` if
      `:out` was not set, as for `:apply` / `:destroy`).
    * Failure → `{:error, %{exit_status: status}, errors}` where
      `errors` is the chronological list of error-severity diagnostic
      lines, each the raw decoded JSON map terraform emitted (keys
      like `"type"`, `"@level"`, `"@message"`, `"diagnostic"` with
      nested `"severity"`, `"summary"`, `"detail"`, `"range"`).

  After the run the output lives at `workflow.output[step_id]` and the
  error list lives at `workflow.errors[step_id]`.

  The Task running this provider also responds to a `:cancel` message:
  on receipt it calls `OsCommand.cancel/1` to SIGTERM the terraform
  process, drains the remaining `:erlexec` messages, and returns
  `{:error, :cancelled}`.
  """

  @behaviour Atlas.Workflow.Step.Provider

  alias Atlas.Workflows.Event
  alias Atlas.Workflows.OsCommand
  alias Atlas.Workflows.PubSub

  @impl true
  def call(arguments, _data, ctx) do
    with {:ok, action} <- fetch(arguments, :action),
         {:ok, cwd} <- fetch(arguments, :working_directory),
         :ok <- validate_action(action) do
      config = %{
        executable: Map.get(arguments, :binary, "terraform"),
        arguments: build_argv(action, arguments),
        cwd: cwd,
        env: Map.get(arguments, :env, %{})
      }

      Atlas.Log.info(
        log_id(ctx),
        "running `#{config.executable} #{Enum.join(config.arguments, " ")}` in #{cwd}"
      )

      case OsCommand.start(config) do
        {:ok, state} ->
          with {:ok, output} <- consume(state, [], ctx) do
            Atlas.Log.info(log_id(ctx), "terraform #{action} succeeded")

            if action === :plan do
              {:ok, Map.put(output, :result, %{plan: arguments[:out]})}
            else
              {:ok, output}
            end
          end

        {:error, reason} ->
          Atlas.Log.error(log_id(ctx), "failed to start terraform: #{inspect(reason)}")
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

  defp validate_action(a) when a in [:apply, :destroy, :init, :plan], do: :ok
  defp validate_action(other), do: {:error, {:invalid_action, other}}

  defp build_argv(:init, _arguments) do
    ["init", "-no-color", "-input=false"]
  end

  defp build_argv(action, arguments) do
    base = [Atom.to_string(action), "-json", "-no-color"]

    case Map.get(arguments, :plan) do
      path when is_binary(path) -> base ++ [path]
      nil -> build_argv_flags(base, action, arguments)
    end
  end

  defp build_argv_flags(base, action, arguments) do
    base =
      if Map.get(arguments, :auto_approve, action != :plan),
        do: base ++ ["-auto-approve"],
        else: base

    base =
      case Map.get(arguments, :out) do
        nil -> base
        path when is_binary(path) -> base ++ ["-out=#{path}"]
      end

    base =
      case Map.get(arguments, :var_file) do
        nil -> base
        path when is_binary(path) -> base ++ ["-var-file=#{path}"]
      end

    var_args =
      arguments
      |> Map.get(:vars, %{})
      |> Enum.flat_map(fn {k, v} -> ["-var", "#{k}=#{v}"] end)

    base ++ var_args
  end

  defp consume(state, errors, ctx) do
    receive do
      :cancel ->
        Atlas.Log.warn(log_id(ctx), "cancel signal received, sending SIGTERM to terraform")
        OsCommand.cancel(state)
        drain(state, errors, ctx)
        {:error, :cancelled}

      msg ->
        case OsCommand.handle_message(msg, state) do
          {:lines, lines, new_state} ->
            consume(new_state, handle_lines(lines, errors, ctx), ctx)

          {:exit, 0, tails, _new_state} ->
            _ = handle_lines(tails, errors, ctx)
            {:ok, %{exit_status: 0}}

          {:exit, status, tails, _new_state} ->
            final = handle_lines(tails, errors, ctx) |> Enum.reverse()

            Atlas.Log.error(
              log_id(ctx),
              "terraform exited #{status} with #{length(final)} error diagnostic(s)"
            )

            {:error, %{exit_status: status}, final}

          {:noop, new_state} ->
            consume(new_state, errors, ctx)
        end
    end
  end

  defp drain(state, errors, ctx) do
    receive do
      msg ->
        case OsCommand.handle_message(msg, state) do
          {:exit, _status, tails, _new_state} ->
            _ = handle_lines(tails, errors, ctx)
            :ok

          {:lines, lines, new_state} ->
            drain(new_state, handle_lines(lines, errors, ctx), ctx)

          {:noop, new_state} ->
            drain(new_state, errors, ctx)
        end
    after
      5_000 -> :ok
    end
  end

  defp handle_lines(lines, errors, ctx) do
    Enum.reduce(lines, errors, fn {_stream, line}, errors ->
      handle_line(line, errors, ctx)
    end)
  end

  defp handle_line(line, errors, ctx) do
    case JSON.decode(line) do
      {:ok, %{"type" => "diagnostic", "@level" => "error"} = msg} ->
        Atlas.Log.error(log_id(ctx), "diagnostic: #{msg["@message"]}")

        PubSub.publish(
          ctx.workflow_id,
          Event.terraform_diagnostic(ctx.workflow_id, :error, msg)
        )

        [msg | errors]

      {:ok, %{"type" => "diagnostic"} = msg} ->
        Atlas.Log.warn(log_id(ctx), "diagnostic: #{msg["@message"]}")

        PubSub.publish(
          ctx.workflow_id,
          Event.terraform_diagnostic(ctx.workflow_id, :warning, msg)
        )

        errors

      {:ok, %{"type" => _} = msg} ->
        case build_event(msg, ctx.workflow_id) do
          %Event{} = event ->
            log_resource_event(event, ctx)
            PubSub.publish(ctx.workflow_id, event)

          nil ->
            :ok
        end

        errors

      _ ->
        errors
    end
  end

  defp log_resource_event(%Event{name: name}, ctx) do
    case name do
      ["workflow", _, "terraform", resource_type, "failed", resource_name] ->
        Atlas.Log.error(log_id(ctx), "#{resource_type}.#{resource_name} failed")

      ["workflow", _, "terraform", resource_type, lifecycle, resource_name]
      when lifecycle in [
             "planned",
             "creating",
             "updating",
             "destroying",
             "created",
             "updated",
             "destroyed"
           ] ->
        Atlas.Log.info(log_id(ctx), "#{resource_type}.#{resource_name} #{lifecycle}")

      _ ->
        :ok
    end
  end

  defp build_event(%{"type" => "planned_change", "change" => %{"resource" => r}} = msg, wf_id) do
    Event.terraform_resource(wf_id, r["resource_type"], :planned, r["resource_name"], %{raw: msg})
  end

  defp build_event(
         %{"type" => "apply_start", "hook" => %{"resource" => r, "action" => a}} = msg,
         wf_id
       ) do
    Event.terraform_resource(wf_id, r["resource_type"], apply_start(a), r["resource_name"], %{
      raw: msg
    })
  end

  defp build_event(
         %{"type" => "apply_complete", "hook" => %{"resource" => r, "action" => a} = hook} = msg,
         wf_id
       ) do
    Event.terraform_resource(wf_id, r["resource_type"], apply_complete(a), r["resource_name"], %{
      raw: msg,
      resource_id: hook["id_value"]
    })
  end

  defp build_event(%{"type" => "apply_errored", "hook" => %{"resource" => r}} = msg, wf_id) do
    Event.terraform_resource(wf_id, r["resource_type"], :failed, r["resource_name"], %{raw: msg})
  end

  defp build_event(_, _), do: nil

  defp apply_start("create"), do: :creating
  defp apply_start("update"), do: :updating
  defp apply_start("delete"), do: :destroying
  defp apply_start(_), do: :creating

  defp apply_complete("create"), do: :created
  defp apply_complete("update"), do: :updated
  defp apply_complete("delete"), do: :destroyed
  defp apply_complete(_), do: :created
end
