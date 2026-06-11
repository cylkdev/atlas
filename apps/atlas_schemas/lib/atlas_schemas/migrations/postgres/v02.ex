defmodule AtlasSchemas.Migrations.Postgres.V02 do
  @moduledoc false
  use Ecto.Migration

  # Creates the Oban tables Atlas.Oban requires. `Oban.Migrations`
  # dispatches on the repo adapter, so this works for both the bundled
  # Postgres repo and a host-supplied SQLite repo.
  def up do
    Oban.Migrations.up(version: 14)
  end

  def down do
    Oban.Migrations.down(version: 1)
  end
end
