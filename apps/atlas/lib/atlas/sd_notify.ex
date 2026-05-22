defmodule Atlas.SdNotify do
  @moduledoc """
  Implements the systemd `sd_notify` protocol so that a `Type=notify` unit
  knows when the OTP application is ready and is still alive.

  ## Why this exists

  A systemd unit using `Type=notify` with `WatchdogSec` requires an
  in-process notifier. Without one, systemd will:

    * kill the service at `TimeoutStartSec` because no `READY=1` ever
      arrives, and
    * (if `WatchdogSec` is set) restart the service when no `WATCHDOG=1`
      heartbeat arrives within the configured window.

  This module is the in-process notifier that satisfies both contracts.

  ## Protocol summary

  systemd talks `sd_notify` over a Unix datagram socket whose path it
  passes via the `NOTIFY_SOCKET` environment variable. The payload is
  plain ASCII, one `KEY=VALUE` per datagram. This module sends two
  payloads:

      READY=1       # once, after the supervisor has started the watchdog
      WATCHDOG=1    # repeated, at half of WATCHDOG_USEC microseconds

  Two flavours of socket path are recognised:

      "/run/systemd/notify"   # filesystem socket  (path starts with "/")
      "@some_notify"          # abstract namespace (Linux-only; "@" → leading NUL)

  Anything else is treated as a misconfiguration: the module logs a
  warning and becomes a no-op.

  ## When this module is a no-op

    * `NOTIFY_SOCKET` env var is unset or empty (dev / test path)
    * the configured socket path has an unrecognised shape
    * opening the socket or sending the initial `READY=1` fails

  In all of these cases `init/1` returns `:ignore`, so the supervisor
  continues starting other children. The watchdog never crashes its
  supervisor.

  ## Liveness gate

  `WATCHDOG=1` is only sent when the configured
  `Atlas.SdNotify.HealthCheck` implementation returns
  `true` from `healthy?/0`. When the predicate returns `false`, the
  heartbeat tick is skipped (so systemd will eventually restart the unit)
  but scheduling continues so the service can recover from a transient
  failure.
  """

  use GenServer

  require Logger

  @type opts :: [
          name: GenServer.name() | nil,
          notify_socket: String.t() | nil,
          watchdog_usec: String.t() | nil
        ]

  @typep state :: %{
           socket: :socket.socket(),
           sockaddr: map(),
           heartbeat_ms: pos_integer() | nil,
           health_check_module: module()
         }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns a child spec for use in a supervisor child list.

  Two shapes are accepted:

    * `{health_check_module, opts}` — tuple form.
    * `opts` keyword list with `:health_check_module` set — delegates to
      the tuple form after popping the key. This is what the standard
      supervisor syntax
      `{Atlas.SdNotify, health_check_module: MyHealth, ...}`
      produces.
  """
  @spec child_spec({module(), opts()} | keyword()) :: Supervisor.child_spec()
  def child_spec({health_check_module, opts}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [health_check_module, opts]}
    }
  end

  def child_spec(opts) when is_list(opts) do
    opts |> Keyword.pop!(:health_check_module) |> child_spec()
  end

  @doc """
  Starts the watchdog under a supervisor.

  ## Arguments

    * `health_check_module` — module implementing the
      `Atlas.SdNotify.HealthCheck` behaviour. Called on
      every heartbeat to decide whether to send `WATCHDOG=1`.

  ## Options

    * `:name` — registered name for the GenServer. Defaults to
      `__MODULE__`. Pass `nil` to skip name registration (useful in tests
      that start more than one instance).
    * `:notify_socket` — overrides `System.get_env("NOTIFY_SOCKET")`. Pass
      `nil` or `""` to force the no-op path.
    * `:watchdog_usec` — overrides `System.get_env("WATCHDOG_USEC")`. When
      missing or unparseable, no heartbeat loop is scheduled (READY=1 is
      still sent, so startup completes; the service simply has no
      liveness monitor).

  ## Return values

    * `{:ok, pid}` — sd_notify enabled, READY=1 sent.
    * `:ignore`   — running outside systemd, configured to be disabled, or
      the socket could not be opened. Safe for the supervisor to continue.
  """
  @spec start_link(module(), opts()) :: GenServer.on_start()
  def start_link(health_check_module, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, {health_check_module, opts}, gen_opts)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init({health_check_module, opts}) do
    notify_socket = Keyword.get(opts, :notify_socket, System.get_env("NOTIFY_SOCKET"))
    watchdog_usec = Keyword.get(opts, :watchdog_usec, System.get_env("WATCHDOG_USEC"))

    case configure(notify_socket, watchdog_usec, health_check_module) do
      :ignore ->
        :ignore

      {:ok, state} ->
        maybe_schedule_heartbeat(state.heartbeat_ms)
        {:ok, state}
    end
  end

  @impl GenServer
  def handle_info(:heartbeat, %{heartbeat_ms: ms} = state) when is_integer(ms) do
    # Side-effect only: send_payload logs its own {:error, _} via
    # Logger.warning, and the false branch logs too. Both return :ok /
    # {:error, _} which we don't need to act on here — the next heartbeat
    # will retry.
    _heartbeat_result =
      if state.health_check_module.healthy?() do
        send_payload(state, "WATCHDOG=1")
      else
        Logger.warning("[Atlas.SdNotify] health check failed; skipping WATCHDOG=1 ping")
      end

    _timer_ref = Process.send_after(self(), :heartbeat, ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{socket: sock}) do
    case :socket.close(sock) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Atlas.SdNotify] socket close failed: #{inspect(reason)}")

        :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Returns `:ignore` for every disabled/error path; `{:ok, state}` when
  # the socket is open and READY=1 has been sent.
  @spec configure(String.t() | nil, String.t() | nil, module()) ::
          :ignore | {:ok, state()}
  defp configure(notify_socket, _watchdog_usec, _health_check_module)
       when notify_socket in [nil, ""] do
    :ignore
  end

  defp configure(notify_socket, watchdog_usec, health_check_module)
       when is_binary(notify_socket) do
    with {:ok, sockaddr} <- parse_sockaddr(notify_socket),
         {:ok, sock} <- open_socket(),
         :ok <- send_to(sock, sockaddr, "READY=1") do
      state = %{
        socket: sock,
        sockaddr: sockaddr,
        heartbeat_ms: parse_heartbeat_ms(watchdog_usec),
        health_check_module: health_check_module
      }

      {:ok, state}
    else
      {:error, reason} ->
        Logger.warning(
          "[Atlas.SdNotify] disabled: #{inspect(reason)} (NOTIFY_SOCKET=#{inspect(notify_socket)})"
        )

        :ignore
    end
  end

  defp configure(notify_socket, _watchdog_usec, _health_check_module) do
    Logger.warning(
      "[Atlas.SdNotify] disabled: NOTIFY_SOCKET is not a string (got #{inspect(notify_socket)})"
    )

    :ignore
  end

  # Filesystem socket: path begins with "/".
  # Abstract namespace (Linux): path begins with "@" → replace leading char with NUL.
  # Anything else is rejected.
  @spec parse_sockaddr(String.t()) :: {:ok, map()} | {:error, term()}
  defp parse_sockaddr("/" <> _ = path) do
    {:ok, %{family: :local, path: path}}
  end

  defp parse_sockaddr("@" <> rest) do
    {:ok, %{family: :local, path: <<0>> <> rest}}
  end

  defp parse_sockaddr(other) do
    {:error, {:unrecognised_notify_socket_path, other}}
  end

  @spec open_socket() :: {:ok, :socket.socket()} | {:error, term()}
  defp open_socket do
    case :socket.open(:local, :dgram) do
      {:ok, sock} -> {:ok, sock}
      {:error, reason} -> {:error, {:socket_open_failed, reason}}
    end
  end

  @spec send_to(:socket.socket(), map(), binary()) :: :ok | {:error, term()}
  defp send_to(sock, sockaddr, payload) do
    case :socket.sendto(sock, payload, sockaddr) do
      :ok -> :ok
      {:error, reason} -> {:error, {:sendto_failed, reason}}
    end
  end

  # Sends a payload using the state's already-open socket. Logs but never raises.
  @spec send_payload(state(), binary()) :: :ok | {:error, term()}
  defp send_payload(state, payload) do
    case send_to(state.socket, state.sockaddr, payload) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.warning("[Atlas.SdNotify] failed to send #{payload}: #{inspect(reason)}")

        err
    end
  end

  # WATCHDOG_USEC is microseconds. The protocol convention is to ping at
  # half the timeout, expressed in milliseconds → div(usec, 2 * 1_000).
  @spec parse_heartbeat_ms(String.t() | nil) :: pos_integer() | nil
  defp parse_heartbeat_ms(nil), do: nil
  defp parse_heartbeat_ms(""), do: nil

  defp parse_heartbeat_ms(usec_str) when is_binary(usec_str) do
    case Integer.parse(usec_str) do
      {usec, ""} when usec > 0 ->
        ms = div(usec, 2 * 1_000)
        if ms > 0, do: ms, else: nil

      _ ->
        Logger.warning(
          "[Atlas.SdNotify] WATCHDOG_USEC=#{inspect(usec_str)} unparseable; heartbeat disabled"
        )

        nil
    end
  end

  defp parse_heartbeat_ms(_), do: nil

  @spec maybe_schedule_heartbeat(pos_integer() | nil) :: :ok
  defp maybe_schedule_heartbeat(nil), do: :ok

  defp maybe_schedule_heartbeat(ms) when is_integer(ms) and ms > 0 do
    _timer_ref = Process.send_after(self(), :heartbeat, ms)
    :ok
  end
end
