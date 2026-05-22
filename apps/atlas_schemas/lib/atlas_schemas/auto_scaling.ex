defmodule AtlasSchemas.AutoScaling do
  alias EctoShorts.Actions

  alias AtlasSchemas.AutoScaling.Event

  def create_event(params, opts \\ []) do
    Actions.create(Event, params, opts)
  end

  def find_event(params, opts \\ []) do
    Actions.find(Event, params, opts)
  end

  def list_events(params \\ %{}, opts \\ []) do
    Actions.all(Event, params, opts)
  end

  def update_event(id_or_struct, params, opts \\ []) do
    Actions.update(Event, id_or_struct, params, opts)
  end

  def delete_event(struct_or_params, opts \\ []) do
    Actions.delete(Event, struct_or_params, opts)
  end
end
