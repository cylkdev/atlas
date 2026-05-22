defmodule AtlasSchemas.Crates do
  alias EctoShorts.Actions

  alias AtlasSchemas.Crates.{
    Artifact,
    Crate
  }

  def create_crate(params, opts \\ []) do
    Actions.create(Crate, params, opts)
  end

  def find_crate(params, opts \\ []) do
    Actions.find(Crate, params, opts)
  end

  def list_crates(params \\ %{}, opts \\ []) do
    Actions.all(Crate, params, opts)
  end

  def update_crate(id_or_struct, params, opts \\ []) do
    Actions.update(Crate, id_or_struct, params, opts)
  end

  def delete_crate(struct_or_params, opts \\ []) do
    Actions.delete(Crate, struct_or_params, opts)
  end

  def create_artifact(params, opts \\ []) do
    Actions.create(Artifact, params, opts)
  end

  def find_artifact(params, opts \\ []) do
    Actions.find(Artifact, params, opts)
  end

  def update_artifact(id_or_struct, params, opts \\ []) do
    Actions.update(Artifact, id_or_struct, params, opts)
  end

  def delete_artifact(struct_or_params, opts \\ []) do
    Actions.delete(Artifact, struct_or_params, opts)
  end
end
