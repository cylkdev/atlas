defmodule Atlas.Tunnel do
  @moduledoc """
  Cloudflare tunnel lifecycle for Atlas deploy workflows.

  EventBridge can only reach Atlas's `Atlas.Endpoint` (for
  auto-scaling-listen callbacks during a deploy) via a public URL. In
  the consumer's prior pipeline this meant a separately-managed
  Cloudflare tunnel that had to be brought up by hand before deploy
  and torn down by hand after. PLAN.md F2 moves that lifecycle inside
  Atlas: `mix atlas.workflows.deploy` starts a tunnel before the
  workflow runs and stops it on exit.

  ## Backend selection

  Two backends ship in this module's namespace; the deploy task
  selects between them at runtime:

    * `Atlas.Tunnel.Named` — uses a preregistered Cloudflare named
      tunnel. Reads `:token` and `:hostname` from
      `Application.get_env(:atlas, Atlas.Tunnel.Named)`. Public URL is
      the configured `:hostname`.

    * `Atlas.Tunnel.Quick` — runs `cloudflared tunnel --url <local>`
      and captures the `*.trycloudflare.com` URL Cloudflare assigns at
      startup. No preregistration needed.

  The active backend is chosen by `Application.get_env(:atlas,
  :tunnel, :named)`. Accepted values:

    * `:named` (default) → `Atlas.Tunnel.Named`
    * `:quick` → `Atlas.Tunnel.Quick`
    * `:none` → `Atlas.Tunnel.Noop` (no tunnel; for testing /
      reachability-not-required runs)
    * any module that implements this behaviour → used as-is (test
      stubs, custom backends)

  ## Usage shape

      {:ok, pid} = Atlas.Tunnel.start_link()
      {:ok, public_url} = Atlas.Tunnel.url(pid)
      # ... do work that EventBridge will hit at public_url ...
      :ok = Atlas.Tunnel.stop(pid)

  `Mix.Tasks.Atlas.Workflows.Deploy` brackets the pipeline call with
  exactly this shape so the tunnel cannot leak past the deploy.
  """

  @typedoc "A GenServer handle returned by `start_link/1`."
  @type server :: GenServer.server()

  @doc """
  Start the backend process. Returns a standard `GenServer.on_start/0`
  shape so the caller can `try/after` the matching `stop/1`.
  """
  @callback start_link(keyword()) :: GenServer.on_start()

  @doc """
  Return the public URL the running tunnel exposes. May block for a
  short period while the backend learns its URL (e.g. while Quick
  parses cloudflared's stdout).
  """
  @callback url(server()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Stop the backend process and tear down any associated state. Must
  be idempotent — calling `stop/1` on a server that already exited
  returns `:ok` without raising.
  """
  @callback stop(server()) :: :ok

  # --------------------------------------------------------------------
  # Module-level dispatcher

  @doc """
  Return the currently-configured backend module.

  Reads `Application.get_env(:atlas, :tunnel, :named)`. Accepts the
  `:named` / `:quick` / `:none` shorthand atoms and any module name.
  Raises `ArgumentError` for any other value so a typo in config
  fails loudly at deploy time rather than silently running the wrong
  backend.
  """
  @spec backend() :: module()
  def backend do
    case Application.get_env(:atlas, :tunnel, :named) do
      :named -> Atlas.Tunnel.Named
      :quick -> Atlas.Tunnel.Quick
      :none -> Atlas.Tunnel.Noop
      module when is_atom(module) -> module
      other ->
        raise ArgumentError,
              "invalid :atlas, :tunnel config value: #{inspect(other)}. " <>
                "Expected :named, :quick, :none, or a module implementing the " <>
                "Atlas.Tunnel behaviour."
    end
  end

  @doc """
  Start the configured backend. Delegates to `backend().start_link/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: backend().start_link(opts)

  @doc """
  Ask the configured backend for its public URL. Delegates to
  `backend().url/1`.
  """
  @spec url(server()) :: {:ok, String.t()} | {:error, term()}
  def url(server), do: backend().url(server)

  @doc """
  Stop the running backend. Delegates to `backend().stop/1`.
  """
  @spec stop(server()) :: :ok
  def stop(server), do: backend().stop(server)
end
