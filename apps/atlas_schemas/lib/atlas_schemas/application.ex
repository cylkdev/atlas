defmodule AtlasSchemas.Application do
  @moduledoc "Supervises `AtlasSchemas.Repo`."

  use Application

  @impl true
  def start(_type, _args) do
    children = children()
    opts = [strategy: :one_for_one, name: AtlasSchemas.Supervisor]
    Supervisor.start_link(children, opts)
  end

  if Mix.env() in [:dev, :test] do
    def children do
      [AtlasSchemas.Repo]
    end
  else
    def children do
      []
    end
  end
end
