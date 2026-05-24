defmodule AtlasSchemas.Config do
  @moduledoc false

  def repo do
    Application.get_env(:atlas_schemas, :repo, AtlasSchemas.Repo)
  end
end
