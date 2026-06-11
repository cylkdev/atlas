defmodule AtlasSchemas.Crates do
  alias EctoShorts.Actions

  alias AtlasSchemas.Crates.{
    Artifact,
    Crate
  }

  # Every action defaults :repo to AtlasSchemas.Config.repo(). Host
  # applications configure a global ecto_shorts repo for their own
  # schemas; without this default, Atlas queries would run against the
  # host's repo, whose database does not contain the atlas_schemas
  # tables. An explicit :repo in opts still wins.

  def create_crate(params, opts \\ []) do
    Actions.create(Crate, params, with_repo(opts))
  end

  def find_crate(params, opts \\ []) do
    Actions.find(Crate, params, with_repo(opts))
  end

  def list_crates(params \\ %{}, opts \\ []) do
    Actions.all(Crate, params, with_repo(opts))
  end

  def update_crate(id_or_struct, params, opts \\ []) do
    Actions.update(Crate, id_or_struct, params, with_repo(opts))
  end

  def delete_crate(struct_or_params, opts \\ []) do
    Actions.delete(Crate, struct_or_params, with_repo(opts))
  end

  def create_artifact(params, opts \\ []) do
    Actions.create(Artifact, params, with_repo(opts))
  end

  def find_artifact(params, opts \\ []) do
    Actions.find(Artifact, params, with_repo(opts))
  end

  def update_artifact(id_or_struct, params, opts \\ []) do
    Actions.update(Artifact, id_or_struct, params, with_repo(opts))
  end

  def delete_artifact(struct_or_params, opts \\ []) do
    Actions.delete(Artifact, struct_or_params, with_repo(opts))
  end

  defp with_repo(opts) do
    Keyword.put_new(opts, :repo, AtlasSchemas.Config.repo())
  end
end
