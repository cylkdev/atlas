defmodule AtlasSchemas.Application do
  @moduledoc """
  Supervises `AtlasSchemas.Repo`.

  `AtlasSchemas.Repo` is started when it is the configured repo (i.e.
  no host application has overridden `config :atlas_schemas, :repo`).
  When a host supplies its own repo, it is responsible for starting that
  repo — this supervisor starts nothing in that case.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = children()
    opts = [strategy: :one_for_one, name: AtlasSchemas.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def children do
    if AtlasSchemas.Config.mix_env === :dev do
      [AtlasSchemas.Repo]
    else
      []
    end
  end
end
