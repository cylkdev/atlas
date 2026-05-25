defmodule Atlas.Endpoint do
  @moduledoc """
  HTTP endpoint.

  The supervisor itself is **always** present in `Atlas.Application`'s
  tree, but it only starts the underlying Bandit HTTP server when
  `server?/1` returns `true`. The pattern mirrors `Phoenix.Endpoint`:
  the application supervision-tree shape is stable, and the serve /
  don't-serve decision lives here.

  ## Boot gate

  The gate is the logical OR of two `Application` env keys:

    * `:atlas, :serve_endpoints` — the **global** flag, intended to be
      set by `mix atlas.server` (`Application.put_env(:atlas,
      :serve_endpoints, true, persistent: true)` before the `:atlas`
      app starts). Forces every endpoint to serve regardless of
      per-endpoint config.

    * `:atlas, Atlas.Endpoint` `:server` — the **per-endpoint
      declarative** flag, set by the consumer in their config
      (`config :atlas, Atlas.Endpoint, server: true, …`). Lets the
      endpoint serve on every boot of `:atlas` without going through
      the mix task.

  If neither is `true`, `init/1` returns a supervisor with no
  children — the supervisor is alive, no port is bound, and nothing
  about the rest of the supervision tree changes.

  ## Bandit child

  When the gate is open, the supervisor starts:

    * `Bandit` configured with `Atlas.Endpoint.Connection`-wrapped
      plugs (`Atlas.HealthCheckPlug`, `Atlas.Endpoint.Router`), bound
      to the scheme and port from `config :atlas, Atlas.Endpoint, …`.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:atlas, __MODULE__) || [], opts)

    children =
      if server?(config) do
        scheme = Keyword.get(config, :scheme, :http)
        port = Keyword.get(config, :port, 4000)

        plugs = [
          {Atlas.HealthCheckPlug, config},
          {Atlas.Endpoint.Router, config}
        ]

        [{Bandit, plug: {Atlas.Endpoint.Connection, plugs: plugs}, scheme: scheme, port: port}]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns whether this endpoint will start its Bandit HTTP server,
  based on the currently-loaded `Application` env.

  Equivalent to `server?(Application.get_env(:atlas, Atlas.Endpoint,
  []))`. Use this from outside the supervisor (mix tasks, tests, sd_notify
  health checks, etc.) to introspect the current decision.
  """
  @spec server?() :: boolean()
  def server? do
    server?(Application.get_env(:atlas, __MODULE__, []))
  end

  @doc """
  Returns whether the endpoint should serve, given a per-endpoint config
  keyword list. The decision is `:atlas, :serve_endpoints` (global)
  ORed with `config[:server]` (per-endpoint).

  ## Examples

      iex> Application.put_env(:atlas, :serve_endpoints, false)
      iex> Atlas.Endpoint.server?([])
      false

      iex> Application.put_env(:atlas, :serve_endpoints, false)
      iex> Atlas.Endpoint.server?(server: true)
      true

      iex> Application.put_env(:atlas, :serve_endpoints, true)
      iex> Atlas.Endpoint.server?([])
      true
  """
  @spec server?(keyword()) :: boolean()
  def server?(config) when is_list(config) do
    Application.get_env(:atlas, :serve_endpoints, false) === true or
      Keyword.get(config, :server, false) === true
  end
end
