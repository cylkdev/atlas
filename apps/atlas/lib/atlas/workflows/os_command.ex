defmodule Atlas.Workflows.OsCommand do
  @moduledoc """
  Pure-function helpers for providers that drive an OS command.

  Not a behaviour, not a GenServer. A kit of stateful functions a
  provider can call: spawn an OS process via `:erlexec`/`ElixirExec`,
  fold incoming `:erlexec` messages into complete output lines, and
  signal the OS process to stop.

  ## State shape

      %{
        controller: pid(),
        os_pid:     non_neg_integer(),
        buffers:    %{stdout: binary(), stderr: binary()}
      }

  ## Calling `start/1`

  The caller becomes the recipient of `:erlexec`'s
  `{:stdout, _, _}`, `{:stderr, _, _}`, `{:DOWN, _, _, _, _}`, and
  `{:EXIT, _, _}` messages. Providers must therefore call `start/1`
  from the Task process (the same process that feeds those messages
  back through `handle_message/2`).
  """

  alias ElixirExec.Handle

  @type state :: %{
          controller: pid(),
          os_pid: non_neg_integer(),
          buffers: %{stdout: binary(), stderr: binary()}
        }

  @type line :: {:stdout | :stderr, binary()}

  @spec start(map()) :: {:ok, state()} | {:error, term()}
  def start(%{executable: executable, arguments: arguments} = config)
      when is_binary(executable) and is_list(arguments) do
    command = [executable | arguments]

    run_opts =
      [monitor: true, stdout: true, stderr: true, kill_timeout: 1]
      |> maybe_put(:cd, Map.get(config, :cwd))
      |> maybe_put(:env, Map.get(config, :env, %{}))

    case ElixirExec.run(command, run_opts) do
      {:ok, %ElixirExec.Handle{controller: ctrl, os_pid: os_pid}} ->
        {:ok, %{controller: ctrl, os_pid: os_pid, buffers: %{stdout: "", stderr: ""}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec handle_message(term(), state()) ::
          {:lines, [line()], state()}
          | {:exit, term(), [line()], state()}
          | {:noop, state()}
  def handle_message({:stdout, os_pid, chunk}, %{os_pid: os_pid} = state) do
    fold_chunk(:stdout, chunk, state)
  end

  def handle_message({:stderr, os_pid, chunk}, %{os_pid: os_pid} = state) do
    fold_chunk(:stderr, chunk, state)
  end

  def handle_message({:DOWN, os_pid, :process, _ctrl, reason}, %{os_pid: os_pid} = state) do
    finalize_exit(reason, state)
  end

  def handle_message({:EXIT, ctrl, reason}, %{controller: ctrl} = state) do
    finalize_exit(reason, state)
  end

  def handle_message(_msg, state), do: {:noop, state}

  @spec cancel(state()) :: :ok
  def cancel(state) do
    _ = ElixirExec.stop(state.controller)
    :ok
  end

  defp fold_chunk(stream, chunk, state) do
    {complete, rest} = split_lines(state.buffers[stream] <> chunk)
    new_state = %{state | buffers: Map.put(state.buffers, stream, rest)}
    {:lines, Enum.map(complete, fn line -> {stream, line} end), new_state}
  end

  defp finalize_exit(reason, state) do
    tails =
      Enum.flat_map([:stdout, :stderr], fn stream ->
        case state.buffers[stream] do
          "" -> []
          tail -> [{stream, tail}]
        end
      end)

    decoded = Handle.decode_reason(reason)
    status = exit_status_from(decoded)
    flushed_state = %{state | buffers: %{stdout: "", stderr: ""}}

    {:exit, status, tails, flushed_state}
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)
    {complete, tail}
  end

  defp exit_status_from(:normal), do: 0

  defp exit_status_from(n) when is_integer(n) do
    case ElixirExec.status(n) do
      {:status, code} -> code
      other -> other
    end
  end

  defp exit_status_from(other), do: other

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
