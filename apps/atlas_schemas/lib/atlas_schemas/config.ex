defmodule AtlasSchemas.Config do
  @moduledoc false

  def repo do
    Application.get_env(:ecto_shorts, :repo) || AtlasSchemas.Repo
  end
end
