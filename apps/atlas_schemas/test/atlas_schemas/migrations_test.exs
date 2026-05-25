defmodule AtlasSchemas.MigrationsTest do
  # async: false because the tests mutate :atlas_schemas application env
  # for AtlasSchemas.Repo to drive the SQLite branch.
  use ExUnit.Case, async: false

  alias AtlasSchemas.Migrations

  describe "ensure_database_directory!/0 — Postgres (current shipped config)" do
    test "is a no-op and creates no directory when the configured adapter is Postgres" do
      # Umbrella ships AtlasSchemas.Repo wired to Ecto.Adapters.Postgres.
      assert AtlasSchemas.Repo.__adapter__() == Ecto.Adapters.Postgres

      tmp = make_tmp_root()
      ghost = Path.join([tmp, "should-not-exist", "x.db"])

      # Even if a fake :database key were present, Postgres should skip.
      with_temp_repo_config([database: ghost], fn ->
        assert :ok = Migrations.ensure_database_directory!()
      end)

      refute File.dir?(Path.dirname(ghost))
    end
  end

  describe "ensure_database_directory!/0 — SQLite branch" do
    @describetag :sqlite

    setup do
      # Drive the SQLite branch by swapping AtlasSchemas.Config.repo() to
      # a fake repo module whose __adapter__/0 returns SQLite3 and whose
      # :database config we control.
      original_repo = Application.get_env(:atlas_schemas, :repo, AtlasSchemas.Repo)
      Application.put_env(:atlas_schemas, :repo, AtlasSchemas.MigrationsTest.FakeSqliteRepo)

      on_exit(fn ->
        Application.put_env(:atlas_schemas, :repo, original_repo)
      end)

      :ok
    end

    test "creates the parent directory when it does not exist" do
      tmp = make_tmp_root()
      db_path = Path.join([tmp, "nested", "deeper", "cylk.db"])

      refute File.dir?(Path.dirname(db_path))

      with_temp_repo_config([database: db_path], fn ->
        assert :ok = Migrations.ensure_database_directory!()
      end)

      assert File.dir?(Path.dirname(db_path))
    end

    test "is idempotent when the parent directory already exists" do
      tmp = make_tmp_root()
      db_path = Path.join([tmp, "cylk.db"])
      File.mkdir_p!(Path.dirname(db_path))

      with_temp_repo_config([database: db_path], fn ->
        assert :ok = Migrations.ensure_database_directory!()
        assert :ok = Migrations.ensure_database_directory!()
      end)

      assert File.dir?(Path.dirname(db_path))
    end

    test "does NOT create the database file itself, only the parent dir" do
      tmp = make_tmp_root()
      db_path = Path.join([tmp, "data", "cylk.db"])

      with_temp_repo_config([database: db_path], fn ->
        assert :ok = Migrations.ensure_database_directory!()
      end)

      refute File.exists?(db_path)
      assert File.dir?(Path.dirname(db_path))
    end

    test "is a no-op when :database config is missing" do
      with_temp_repo_config([], fn ->
        assert :ok = Migrations.ensure_database_directory!()
      end)
    end

    test "is a no-op when :database config is non-binary" do
      with_temp_repo_config([database: :not_a_path], fn ->
        assert :ok = Migrations.ensure_database_directory!()
      end)
    end
  end

  # --------------------------------------------------------------------

  defp make_tmp_root do
    dir =
      Path.join([
        System.tmp_dir!(),
        "atlas-schemas-migrations-test-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp with_temp_repo_config(config, fun) do
    repo = AtlasSchemas.Config.repo()
    original = Application.get_env(:atlas_schemas, repo)
    Application.put_env(:atlas_schemas, repo, config)

    try do
      fun.()
    after
      case original do
        nil -> Application.delete_env(:atlas_schemas, repo)
        value -> Application.put_env(:atlas_schemas, repo, value)
      end
    end
  end

  # --------------------------------------------------------------------
  # Test-only fake repo module that reports the SQLite3 adapter without
  # actually wiring an Ecto connection pool. Used only by the
  # :sqlite-tagged tests in this file.
  defmodule FakeSqliteRepo do
    @moduledoc false

    def __adapter__, do: Ecto.Adapters.SQLite3
  end
end
