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
  Ensures the parent directory of the configured repo's database file
  exists when the repo uses `Ecto.Adapters.SQLite3`. Idempotent — the
  underlying `File.mkdir_p!/1` is a no-op if the directory is already
  there. No-op for every other adapter (including Postgres), where
  the database is owned by an external server and Atlas does not
  manage a file path.

  Called from both `migrate/0` (right before
  `Ecto.Migrator.with_repo/3` opens the database) and from
  `Mix.Tasks.Atlas.Init.run/1` (immediately after the application
  tree is up). Putting the call in both places gives the explicit
  step at the mix-task layer where it belongs *and* a defensive
  call adjacent to the actual open, with no behavioural change from
  the second call because `File.mkdir_p!/1` is idempotent.

  Returns `:ok` on success and raises on filesystem failure
  (permission denied, etc.).
  """
  @spec ensure_database_directory!() :: :ok
  def ensure_database_directory! do
    repo = AtlasSchemas.Config.repo()

    with Ecto.Adapters.SQLite3 <- repo.__adapter__(),
         database when is_binary(database) <- repo_database_path(repo) do
      database |> Path.dirname() |> File.mkdir_p!()
      :ok
    else
      _ -> :ok
    end
  end

  defp repo_database_path(repo) do
    :atlas_schemas
    |> Application.get_env(repo, [])
    |> Keyword.get(:database)
  end

  @doc """
  Runs all pending migrations against `AtlasSchemas.Config.repo()`.

  Calls `ensure_database_directory!/0` first so a SQLite-configured
  repo finds its parent directory in place before `Ecto.Migrator`
  opens the database. Then uses `Ecto.Migrator.with_repo/3` to start
  the repo if it is not already running and apply each pending
  version listed in `AtlasSchemas.Migrations.Postgres.migrations/0`.

  Returns `:ok` on success and raises on failure.
  """
  @spec migrate() :: :ok
  def migrate do
    :ok = ensure_database_directory!()

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
