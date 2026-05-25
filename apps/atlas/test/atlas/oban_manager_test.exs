defmodule Atlas.ObanManagerTest do
  use ExUnit.Case, async: true

  alias Atlas.ObanManager

  describe "engine_for_adapter!/1" do
    test "returns Oban.Engines.Lite for SQLite3" do
      assert ObanManager.engine_for_adapter!(Ecto.Adapters.SQLite3) ==
               Oban.Engines.Lite
    end

    test "returns Oban.Engines.Basic for Postgres" do
      assert ObanManager.engine_for_adapter!(Ecto.Adapters.Postgres) ==
               Oban.Engines.Basic
    end

    test "raises ArgumentError naming the offending adapter for an unsupported value" do
      assert_raise ArgumentError, ~r/Unsupported adapter for Atlas Oban/, fn ->
        ObanManager.engine_for_adapter!(Ecto.Adapters.MyExotic)
      end
    end

    test "raises ArgumentError that names both supported adapters in its message" do
      assert_raise ArgumentError,
                   ~r/Postgres.*SQLite3|SQLite3.*Postgres/s,
                   fn -> ObanManager.engine_for_adapter!(:not_a_module) end
    end
  end

  describe "supervisor_child_spec/0" do
    test "the umbrella ships AtlasSchemas.Repo wired to the Postgres adapter" do
      # Sanity: prevents a future change to AtlasSchemas.Repo from silently
      # breaking the assumption the next test relies on.
      assert AtlasSchemas.Repo.__adapter__() == Ecto.Adapters.Postgres
    end

    test "returns {Oban, opts} with engine derived as Basic for the Postgres-backed repo" do
      {mod, opts} = ObanManager.supervisor_child_spec()

      assert mod == Oban
      assert opts[:engine] == Oban.Engines.Basic
    end

    test "binds the repo to AtlasSchemas.Config.repo/0 by default" do
      {_mod, opts} = ObanManager.supervisor_child_spec()

      assert opts[:repo] == AtlasSchemas.Config.repo()
    end

    test "an explicit :engine in :atlas Oban config wins over the derived engine" do
      original = Application.get_env(:atlas, Oban, [])

      try do
        Application.put_env(:atlas, Oban, Keyword.put(original, :engine, Oban.Engines.Lite))

        {_mod, opts} = ObanManager.supervisor_child_spec()
        assert opts[:engine] == Oban.Engines.Lite
      after
        Application.put_env(:atlas, Oban, original)
      end
    end

    test "always sets the configured Oban instance name" do
      {_mod, opts} = ObanManager.supervisor_child_spec()
      assert opts[:name] == Application.get_env(:atlas, :oban_name)
    end

    test "always declares the stripe queue" do
      {_mod, opts} = ObanManager.supervisor_child_spec()
      assert opts[:queues] == [stripe: 10]
    end

    test "always declares the Pruner plugin by default" do
      {_mod, opts} = ObanManager.supervisor_child_spec()
      assert Oban.Plugins.Pruner in opts[:plugins]
    end
  end
end
