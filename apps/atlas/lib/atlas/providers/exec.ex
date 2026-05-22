defmodule Atlas.Providers.Exec do
  @moduledoc """
  General-purpose provider that runs an OS command via
  `Atlas.Workflows.OsCommand` (`:erlexec`/`ElixirExec`), the same
  helper used by `Atlas.Providers.Terraform` and `Atlas.Providers.Ansible`.

  Required arguments:
    * `:executable` (string) — the program to run.

  Optional arguments:
    * `:arguments` (list of strings) — defaults to `[]`.
    * `:working_directory` (string) — defaults to `File.cwd!()`.
    * `:env` (map of `binary => binary`) — inline environment variables.
    * `:env_file` (string) — path to a dotenv-style file. Parsed and
      merged into the command's environment before `:env`. Inline `:env`
      keys override file keys.

  Dotenv parsing supports `KEY=VALUE` lines, `#` comments, blank lines,
  an optional `export ` prefix, and matched surrounding `"..."` or
  `'...'` quotes around values. No escape-sequence processing.

  Return values:
    * Success → `{:ok, %{exit_status: 0}}`.
    * Failure → `{:error, %{exit_status: status}, []}`.
    * Missing env_file → `{:error, %{reason: :env_file_not_found, path: path}, []}`.
    * Cancelled (Task received `:cancel`) → `{:error, :cancelled}`.
    * Start failure → `{:error, reason}`.
  """

  @behaviour Atlas.Workflow.Step.Provider

  alias Atlas.Workflows.OsCommand

  @impl true
  def call(arguments, _data, ctx) do
    with {:ok, executable} <- fetch_executable(arguments),
         {:ok, env} <- build_env(arguments) do
      config = %{
        executable: executable,
        arguments: Map.get(arguments, :arguments, []),
        cwd: Map.get(arguments, :working_directory, File.cwd!()),
        env: env
      }

      Atlas.Log.info(
        log_id(ctx),
        "running `#{config.executable} #{Enum.join(config.arguments, " ")}` in #{config.cwd}"
      )

      case OsCommand.start(config) do
        {:ok, state} ->
          consume(state, ctx)

        {:error, reason} ->
          Atlas.Log.error(log_id(ctx), "failed to start #{config.executable}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp fetch_executable(arguments) do
    case Map.fetch(arguments, :executable) do
      {:ok, executable} when is_binary(executable) and executable != "" ->
        {:ok, executable}

      _ ->
        {:error, %{reason: :missing_executable}, []}
    end
  end

  defp build_env(arguments) do
    inline = Map.get(arguments, :env, %{})

    case Map.get(arguments, :env_file) do
      nil ->
        {:ok, inline}

      path when is_binary(path) ->
        case parse_env_file(path) do
          {:ok, file_env} -> {:ok, Map.merge(file_env, inline)}
          {:error, :enoent} -> {:error, %{reason: :env_file_not_found, path: path}, []}
        end
    end
  end

  defp parse_env_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        env =
          contents
          |> String.split("\n")
          |> Enum.reduce(%{}, fn line, acc ->
            case parse_env_line(line) do
              {:ok, key, value} -> Map.put(acc, key, value)
              :skip -> acc
            end
          end)

        {:ok, env}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_env_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> :skip
      String.starts_with?(trimmed, "#") -> :skip
      true -> parse_env_assignment(strip_export(trimmed))
    end
  end

  defp strip_export("export " <> rest), do: String.trim_leading(rest)
  defp strip_export(line), do: line

  defp parse_env_assignment(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)

        if key == "" do
          :skip
        else
          {:ok, key, unquote_value(String.trim(value))}
        end

      _ ->
        :skip
    end
  end

  defp unquote_value(value) do
    cond do
      match_quoted?(value, "\"") -> String.slice(value, 1..-2//1)
      match_quoted?(value, "'") -> String.slice(value, 1..-2//1)
      true -> value
    end
  end

  defp match_quoted?(value, q) do
    byte_size(value) >= 2 and String.starts_with?(value, q) and String.ends_with?(value, q)
  end

  defp log_id(ctx), do: "workflow:#{ctx.workflow_id}:#{ctx.step_id}"

  defp consume(state, ctx) do
    receive do
      :cancel ->
        Atlas.Log.warn(log_id(ctx), "cancel signal received, sending SIGTERM")
        OsCommand.cancel(state)
        drain(state)
        {:error, :cancelled}

      msg ->
        case OsCommand.handle_message(msg, state) do
          {:lines, lines, new_state} ->
            log_lines(lines, ctx)
            consume(new_state, ctx)

          {:exit, 0, tails, _new_state} ->
            log_lines(tails, ctx)
            Atlas.Log.info(log_id(ctx), "command succeeded")
            {:ok, %{exit_status: 0}}

          {:exit, status, tails, _new_state} ->
            log_lines(tails, ctx)
            Atlas.Log.error(log_id(ctx), "command exited #{status}")
            {:error, %{exit_status: status}, []}

          {:noop, new_state} ->
            consume(new_state, ctx)
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

  defp log_lines(lines, ctx) do
    Enum.each(lines, fn
      {:stdout, line} -> Atlas.Log.info(log_id(ctx), line)
      {:stderr, line} -> Atlas.Log.warn(log_id(ctx), line)
    end)
  end
end
