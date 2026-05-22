defmodule AtlasSchemas.Migrations do
  @moduledoc """
  Public API for running the migrations bundled with `atlas_schemas`.

  `atlas_schemas` owns the schema for `AtlasSchemas.Config.repo()`.
  Migration definitions live as code under
  `AtlasSchemas.Migrations.Postgres.V##`, not as files in
  `priv/repo/migrations`, so the host application's repo can pull them
  in regardless of where its own `:otp_app` priv directory points.

  The Atlas CLI (`mix atlas.*`) calls `migrate/0` before any task that
  touches the database, so the host app does not need to run migrations
  by hand.

  See [`Ecto.Migrator`](https://hexdocs.pm/ecto_sql/Ecto.Migrator.html)
  for the underlying primitives, and
  `AtlasSchemas.Migrations.Postgres.migrations/0` for the registry that
  drives both `migrate/0` and `rollback/1`.
  """

  @doc """
  Runs all pending migrations against `AtlasSchemas.Config.repo()`.

  Uses `Ecto.Migrator.with_repo/3` so the repo is started if it is not
  already running. Each pending version listed in
  `AtlasSchemas.Migrations.Postgres.migrations/0` is applied and
  recorded in `schema_migrations`.

  Returns `:ok` on success and raises on failure.
  """
  @spec migrate() :: :ok
  def migrate do
    {:ok, _migrated, _apps} =
      Ecto.Migrator.with_repo(
        AtlasSchemas.Config.repo(),
        fn repo ->
          Ecto.Migrator.run(
            repo,
            AtlasSchemas.Migrations.Postgres.migrations(),
            :up,
            all: true
          )
        end
      )

    :ok
  end

  @doc """
  Rolls `AtlasSchemas.Config.repo()` back to (and including) `version`.

  `version` is the small integer from the
  `AtlasSchemas.Migrations.Postgres.migrations/0` registry (e.g. `1`
  for `V01`, the initial schema covering `crates` and `artifacts`).
  """
  @spec rollback(integer()) :: :ok
  def rollback(version) when is_integer(version) do
    {:ok, _migrated, _apps} =
      Ecto.Migrator.with_repo(
        AtlasSchemas.Config.repo(),
        fn repo ->
          Ecto.Migrator.run(
            repo,
            AtlasSchemas.Migrations.Postgres.migrations(),
            :down,
            to: version
          )
        end
      )

    :ok
  end
end
