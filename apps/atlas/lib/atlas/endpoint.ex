defmodule Atlas.Endpoint do
  @moduledoc """
  HTTP endpoint.

  Children:
    * `Bandit` configured with `Atlas.Router`, bound to the scheme and
      port from `config :atlas, Atlas.Endpoint, …`.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:atlas, __MODULE__) || [], opts)
    scheme = Keyword.get(config, :scheme, :http)
    port = Keyword.get(config, :port, 4000)

    plugs =
      [
        {Atlas.HealthCheckPlug, config},
        {Atlas.Endpoint.Router, config}
      ]

    children = [{Bandit, plug: {Atlas.Endpoint.Connection, plugs: plugs}, scheme: scheme, port: port}]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
