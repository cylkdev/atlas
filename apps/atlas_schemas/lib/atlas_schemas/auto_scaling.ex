defmodule AtlasSchemas.AutoScaling do
  alias EctoShorts.Actions

  alias AtlasSchemas.AutoScaling.Event

  # Every action defaults :repo to AtlasSchemas.Config.repo(). Host
  # applications configure a global ecto_shorts repo for their own
  # schemas; without this default, Atlas queries would run against the
  # host's repo, whose database does not contain the atlas_schemas
  # tables. An explicit :repo in opts still wins.

  def create_event(params, opts \\ []) do
    Actions.create(Event, params, with_repo(opts))
  end

  def find_event(params, opts \\ []) do
    Actions.find(Event, params, with_repo(opts))
  end

  def list_events(params \\ %{}, opts \\ []) do
    Actions.all(Event, params, with_repo(opts))
  end

  def update_event(id_or_struct, params, opts \\ []) do
    Actions.update(Event, id_or_struct, params, with_repo(opts))
  end

  def delete_event(struct_or_params, opts \\ []) do
    Actions.delete(Event, struct_or_params, with_repo(opts))
  end

  defp with_repo(opts) do
    Keyword.put_new(opts, :repo, AtlasSchemas.Config.repo())
  end
end
