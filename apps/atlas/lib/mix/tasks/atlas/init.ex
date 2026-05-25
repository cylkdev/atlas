defmodule Mix.Tasks.Atlas.Init do
  @shortdoc "Start the Atlas supervision tree and run pending migrations"

  @moduledoc """
  Ensures the `:atlas` supervision tree is running, prepares the
  database filesystem if needed, and applies any pending
  `AtlasSchemas` migrations. All Atlas mix tasks that touch the
  database or the Atlas runtime declare this task as a requirement.

      mix atlas.init

  Mix runs each `@requirements` task at most once per session, so
  declaring `"atlas.init"` in multiple tasks does not cause repeated
  starts or duplicate migrations.

  ## Order of operations

    1. `Application.ensure_all_started(:atlas)` — brings up the
       supervision tree.
    2. `AtlasSchemas.Migrations.ensure_database_directory!/0` —
       creates the parent directory of the configured repo's
       database file when the adapter is SQLite. No-op for Postgres.
       Idempotent.
    3. `AtlasSchemas.Migrations.migrate/0` — opens the database via
       `Ecto.Migrator.with_repo/3` and applies pending migrations.
       This call also invokes `ensure_database_directory!/0`
       internally as a defensive second check; `File.mkdir_p!/1` is
       idempotent, so the duplicate call is free.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    {:ok, _} = Application.ensure_all_started(:atlas)
    :ok = AtlasSchemas.Migrations.ensure_database_directory!()
    :ok = AtlasSchemas.Migrations.migrate()
  end
end
