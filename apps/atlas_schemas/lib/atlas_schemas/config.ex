defmodule AtlasSchemas.Config do
  @moduledoc false

  @app :atlas_schemas

  def mix_env, do: Application.get_env(@app, :mix_env)

  def repo do
    Application.get_env(@app, :repo) || AtlasSchemas.Repo
  end
end
