defmodule Mix.Tasks.Atlas.ServerTest do
  # Sync (ExUnit's default): the test mutates the global `:atlas,
  # :serve_endpoints` application env.
  use ExUnit.Case

  setup do
    original = Application.get_env(:atlas, :serve_endpoints)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:atlas, :serve_endpoints)
        value -> Application.put_env(:atlas, :serve_endpoints, value)
      end
    end)

    :ok
  end

  describe "enable_server!/0" do
    test "sets `:atlas, :serve_endpoints` to true when previously unset" do
      Application.delete_env(:atlas, :serve_endpoints)
      refute Atlas.Endpoint.server?()

      :ok = Mix.Tasks.Atlas.Server.enable_server!()

      assert Application.get_env(:atlas, :serve_endpoints) === true
      assert Atlas.Endpoint.server?()
    end

    test "flips `:atlas, :serve_endpoints` from false to true" do
      Application.put_env(:atlas, :serve_endpoints, false)
      refute Atlas.Endpoint.server?()

      :ok = Mix.Tasks.Atlas.Server.enable_server!()

      assert Application.get_env(:atlas, :serve_endpoints) === true
      assert Atlas.Endpoint.server?()
    end

    test "is idempotent when `:atlas, :serve_endpoints` is already true" do
      Application.put_env(:atlas, :serve_endpoints, true)
      assert Atlas.Endpoint.server?()

      :ok = Mix.Tasks.Atlas.Server.enable_server!()

      assert Application.get_env(:atlas, :serve_endpoints) === true
      assert Atlas.Endpoint.server?()
    end

    test "does not touch the per-endpoint `:atlas, Atlas.Endpoint` config" do
      original = Application.get_env(:atlas, Atlas.Endpoint)
      :ok = Mix.Tasks.Atlas.Server.enable_server!()

      assert Application.get_env(:atlas, Atlas.Endpoint) === original
    end
  end
end
