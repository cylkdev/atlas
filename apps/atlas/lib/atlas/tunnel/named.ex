defmodule Atlas.Tunnel.Named do
  @moduledoc """
  `Atlas.Tunnel` backend for a preregistered Cloudflare named tunnel.

  Reads two values from `Application.get_env(:atlas, Atlas.Tunnel.Named)`:

    * `:token` (required) — the Cloudflare tunnel token.
    * `:hostname` (required) — the public DNS hostname registered to
      route at this tunnel (e.g. `"atlas-events.cylk.dev"`).

  Optionally:

    * `:tunnel_name` — Cloudflare's logical tunnel name (default
      `"atlas-events"`).
    * `:scheme` / `:service_domain` / `:service_port` — the local
      service `cloudflared` forwards to. Defaults to
      `http://localhost:4000`.

  ## Lifecycle

    * `start_link/1` provisions the Cloudflare-side ingress route via
      `Flared.MixTask.open_remote/3`, then runs `cloudflared` in a
      supervised `Task` via `Flared.MixTask.up/2`. The `Task` runs
      for the lifetime of the GenServer.
    * `url/1` returns `"https://" <> hostname` immediately — the
      named tunnel's URL is the configured hostname; no parsing of
      cloudflared output is required.
    * `stop/1` invokes `Flared.MixTask.down(name: tunnel_name)` to
      signal `cloudflared`, then `Flared.MixTask.close_remote/3` to
      deprovision the Cloudflare-side ingress, then halts the
      GenServer.

  ## Scope / verification note

  The structural wiring here is covered by unit tests that exercise
  the helper functions (URL composition, option resolution). The
  Flared-side calls (`open_remote`, `up`, `down`, `close_remote`)
  cannot be unit-tested without Cloudflare credentials and a real
  `cloudflared` binary, so they need integration verification
  against a real account before the first production deploy.
  """

  use GenServer

  @behaviour Atlas.Tunnel

  alias Atlas.Log

  @logger_prefix "Atlas.Tunnel.Named"

  @default_tunnel_name "atlas-events"
  @default_scheme :http
  @default_service_domain "localhost"
  @default_service_port 4000

  defstruct [
    :tunnel_name,
    :hostname,
    :url,
    :runner_task
  ]

  @typedoc false
  @type state :: %__MODULE__{
          tunnel_name: String.t(),
          hostname: String.t(),
          url: String.t(),
          runner_task: Task.t() | nil
        }

  # --------------------------------------------------------------------
  # Atlas.Tunnel callbacks

  @impl Atlas.Tunnel
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl Atlas.Tunnel
  def url(server), do: GenServer.call(server, :url)

  @impl Atlas.Tunnel
  def stop(server) do
    if Process.alive?(server) do
      GenServer.stop(server, :normal, 15_000)
    else
      :ok
    end
  end

  # --------------------------------------------------------------------
  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    case resolve_config(opts) do
      {:ok, config} ->
        with {:ok, _provisioned} <- open_remote(config) do
          runner = spawn_cloudflared(config)

          state = %__MODULE__{
            tunnel_name: config.tunnel_name,
            hostname: config.hostname,
            url: url_for(config.hostname),
            runner_task: runner
          }

          {:ok, state}
        else
          {:error, reason} ->
            Log.error(@logger_prefix, "open_remote failed: #{inspect(reason)}")
            {:stop, {:open_remote_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:invalid_config, reason}}
    end
  end

  @impl GenServer
  def handle_call(:url, _from, state) do
    {:reply, {:ok, state.url}, state}
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{} = state) do
    # Stop cloudflared first so it stops issuing connections, then
    # deprovision Cloudflare-side resources.
    _ = Flared.MixTask.down(name: state.tunnel_name)

    case Flared.MixTask.close_remote(state.tunnel_name, [], []) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Log.error(
          @logger_prefix,
          "close_remote failed for #{state.tunnel_name}: #{inspect(reason)}"
        )
    end

    if state.runner_task, do: Task.shutdown(state.runner_task, :brutal_kill)

    :ok
  end

  # --------------------------------------------------------------------
  # Helpers exposed for testability

  @doc """
  Resolves the merged configuration from `Application.get_env/3` plus
  any per-call overrides. Returns `{:ok, map}` on success or
  `{:error, {:missing_key, key}}` when a required key is absent.
  """
  @spec resolve_config(keyword()) ::
          {:ok,
           %{
             tunnel_name: String.t(),
             hostname: String.t(),
             token: String.t(),
             routes: [map()]
           }}
          | {:error, {:missing_key, :token | :hostname}}
  def resolve_config(opts) do
    env = Application.get_env(:atlas, __MODULE__, [])
    merged = Keyword.merge(env, opts)

    with {:ok, token} <- fetch_required(merged, :token),
         {:ok, hostname} <- fetch_required(merged, :hostname) do
      tunnel_name = merged[:tunnel_name] || @default_tunnel_name
      scheme = merged[:scheme] || @default_scheme
      service_domain = merged[:service_domain] || @default_service_domain
      service_port = merged[:service_port] || @default_service_port
      service = "#{scheme}://#{service_domain}:#{service_port}"

      {:ok,
       %{
         tunnel_name: tunnel_name,
         hostname: hostname,
         token: token,
         routes: [%{hostname: hostname, service: service}]
       }}
    end
  end

  @doc """
  Composes the public URL string from a hostname. Always returns
  `"https://<hostname>"` — named tunnels are HTTPS-terminated at
  Cloudflare.
  """
  @spec url_for(String.t()) :: String.t()
  def url_for(hostname) when is_binary(hostname), do: "https://#{hostname}"

  defp fetch_required(opts, key) do
    case opts[key] do
      nil -> {:error, {:missing_key, key}}
      "" -> {:error, {:missing_key, key}}
      value -> {:ok, value}
    end
  end

  defp open_remote(%{tunnel_name: name, routes: routes, token: token}) do
    Flared.MixTask.open_remote(name, routes, token: token)
  end

  defp spawn_cloudflared(%{tunnel_name: name, token: token}) do
    Task.async(fn ->
      Flared.MixTask.up(name, token: token)
    end)
  end
end
