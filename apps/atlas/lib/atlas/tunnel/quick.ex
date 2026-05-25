defmodule Atlas.Tunnel.Quick do
  @moduledoc """
  `Atlas.Tunnel` backend that uses a Cloudflare "quick" tunnel —
  `cloudflared tunnel --url <local>` — and captures the
  `*.trycloudflare.com` URL Cloudflare assigns at startup.

  No Cloudflare account or preregistration needed. The trade-off is
  the assigned URL is ephemeral and unauthenticated, so this backend
  is appropriate for ad-hoc, short-lived sessions (CI deploy jobs
  that wait minutes, local development) and not for long-running
  production tunnels.

  ## Configuration

  Read from `Application.get_env(:atlas, Atlas.Tunnel.Quick)`:

    * `:local_url` (default `"http://localhost:4000"`) — the local
      service `cloudflared` forwards to. Passed as `--url <local>`.
    * `:executable` (default `"cloudflared"`) — the binary to run.
      Useful for tests and for hosts where `cloudflared` lives
      outside the default `PATH`.
    * `:url_timeout_ms` (default `30_000`) — how long `url/1` waits
      for the `*.trycloudflare.com` URL to appear in cloudflared's
      stdout before returning `{:error, :url_timeout}`.

  ## Lifecycle

    * `start_link/1` spawns `cloudflared` via `Port.open/2` and
      starts a `GenServer` to demux its stdout. Lines are scanned
      with `extract_trycloudflare_url/1`; the first match sets the
      GenServer's URL state and unblocks any pending `url/1` calls.
    * `url/1` returns `{:ok, url}` once the URL is captured, or
      `{:error, :url_timeout}` after `:url_timeout_ms` of waiting.
    * `stop/1` closes the port, which terminates the child process.

  ## Scope / verification note

  The structural wiring (URL extraction from stdout, configuration
  merge, GenServer transitions) is covered by unit tests below. The
  actual subprocess interaction with `cloudflared` requires the
  binary installed on the host and a working internet connection to
  Cloudflare, so end-to-end verification needs a real environment.
  """

  use GenServer

  @behaviour Atlas.Tunnel

  alias Atlas.Log

  @logger_prefix "Atlas.Tunnel.Quick"

  @default_local_url "http://localhost:4000"
  @default_executable "cloudflared"
  @default_url_timeout_ms 30_000

  # Matches the URL cloudflared prints on a successful quick-tunnel
  # boot, e.g.
  #   2026-05-25T10:00:00Z INF +-------------------------------------+
  #   2026-05-25T10:00:00Z INF |  https://random-words.trycloudflare.com |
  #   2026-05-25T10:00:00Z INF +-------------------------------------+
  @url_regex ~r/https:\/\/[a-z0-9-]+\.trycloudflare\.com/i

  defstruct [
    :port,
    :url,
    :waiters,
    :buffer
  ]

  @typedoc false
  @type state :: %__MODULE__{
          port: port() | nil,
          url: String.t() | nil,
          waiters: [GenServer.from()],
          buffer: String.t()
        }

  # --------------------------------------------------------------------
  # Atlas.Tunnel callbacks

  @impl Atlas.Tunnel
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl Atlas.Tunnel
  def url(server) do
    timeout = url_timeout_ms()
    GenServer.call(server, :url, timeout + 1_000)
  end

  @impl Atlas.Tunnel
  def stop(server) do
    if Process.alive?(server) do
      GenServer.stop(server, :normal, 5_000)
    else
      :ok
    end
  end

  # --------------------------------------------------------------------
  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    config = resolve_config(opts)

    case open_port(config) do
      {:ok, port} ->
        {:ok, %__MODULE__{port: port, url: nil, waiters: [], buffer: ""}}

      {:error, reason} ->
        {:stop, {:cloudflared_spawn_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:url, _from, %__MODULE__{url: url} = state) when is_binary(url) do
    {:reply, {:ok, url}, state}
  end

  def handle_call(:url, from, %__MODULE__{url: nil} = state) do
    # Defer the reply; a future stdout line (or the url-timeout
    # message) will deliver the answer.
    Process.send_after(self(), {:url_timeout, from}, url_timeout_ms())
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %__MODULE__{port: port} = state) do
    handle_line(line, state)
  end

  def handle_info({port, {:data, {:noeol, partial}}}, %__MODULE__{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> partial}}
  end

  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    Log.error(@logger_prefix, "cloudflared exited with status #{status}")
    reply_to_waiters(state.waiters, {:error, {:cloudflared_exited, status}})
    {:stop, :normal, %{state | port: nil, waiters: []}}
  end

  def handle_info({:url_timeout, from}, %__MODULE__{url: nil, waiters: waiters} = state) do
    if from in waiters do
      GenServer.reply(from, {:error, :url_timeout})
    end

    {:noreply, %{state | waiters: List.delete(waiters, from)}}
  end

  def handle_info({:url_timeout, _from}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %__MODULE__{port: port} = state) when is_port(port) do
    reply_to_waiters(state.waiters, {:error, :shutting_down})
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # --------------------------------------------------------------------
  # Helpers exposed for testability

  @doc """
  Returns the first `https://*.trycloudflare.com` URL found in
  `line`, or `nil`. `line` is expected to be a single line of
  `cloudflared`'s stdout / stderr; this function does NOT split a
  multi-line string.
  """
  @spec extract_trycloudflare_url(String.t()) :: String.t() | nil
  def extract_trycloudflare_url(line) when is_binary(line) do
    case Regex.run(@url_regex, line) do
      [match] -> match
      nil -> nil
    end
  end

  @doc """
  Merges per-call options on top of `Application.get_env(:atlas,
  __MODULE__)`, applying the documented defaults.
  """
  @spec resolve_config(keyword()) :: %{
          local_url: String.t(),
          executable: String.t(),
          url_timeout_ms: pos_integer()
        }
  def resolve_config(opts) do
    env = Application.get_env(:atlas, __MODULE__, [])
    merged = Keyword.merge(env, opts)

    %{
      local_url: merged[:local_url] || @default_local_url,
      executable: merged[:executable] || @default_executable,
      url_timeout_ms: merged[:url_timeout_ms] || @default_url_timeout_ms
    }
  end

  defp url_timeout_ms do
    resolve_config([]).url_timeout_ms
  end

  defp open_port(%{executable: executable, local_url: local_url}) do
    case System.find_executable(executable) do
      nil ->
        {:error, {:executable_not_found, executable}}

      path ->
        args = ["tunnel", "--no-autoupdate", "--url", local_url]

        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            {:line, 4096},
            {:args, args},
            :use_stdio,
            :stderr_to_stdout
          ])

        {:ok, port}
    end
  end

  defp handle_line(line, %__MODULE__{} = state) do
    case extract_trycloudflare_url(line) do
      nil ->
        {:noreply, state}

      url ->
        Log.info(@logger_prefix, "quick tunnel up at #{url}")
        reply_to_waiters(state.waiters, {:ok, url})
        {:noreply, %{state | url: url, waiters: []}}
    end
  end

  defp reply_to_waiters([], _reply), do: :ok

  defp reply_to_waiters(waiters, reply) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end
end
