defmodule AtlasSchemas.Migrations.Postgres do
  @moduledoc """
  Migration version registry for the schemas owned by `atlas_schemas` on
  the Postgres adapter.

  Each `V##` module under this namespace defines one schema version
  using the `Ecto.Migration` DSL. `migrations/0` returns the ordered
  list of `{version, module}` tuples that `Ecto.Migrator.run/4`
  consumes.

  Naming and dispatch follow `Oban.Migrations.Postgres`: the integer
  index is zero-padded to two digits and concatenated as `V##` against
  this module's name, e.g. `AtlasSchemas.Migrations.Postgres.V01`. The
  module atom for each version exists at compile time, so listing the
  registry does not mint new atoms.
  """

  @initial_version 1
  @current_version 1

  @doc """
  Returns the ordered list of `{version, module}` tuples for every
  available migration version, suitable for passing as the
  `migration_source` argument to `Ecto.Migrator.run/4`.
  """
  @spec migrations() :: [{pos_integer(), module()}]
  def migrations do
    Enum.map(@initial_version..@current_version, fn index ->
      {index, version_module(index)}
    end)
  end

  defp version_module(index) do
    pad_idx = String.pad_leading("#{index}", 2, "0")
    Module.concat([__MODULE__, "V#{pad_idx}"])
  end
end
