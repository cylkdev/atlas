defmodule Atlas.EndpointTest do
  # Sync (ExUnit's default): the tests mutate `:atlas, :serve_endpoints`
  # and `:atlas, Atlas.Endpoint` application env, which are global.
  use ExUnit.Case

  setup do
    original_global = Application.get_env(:atlas, :serve_endpoints)
    original_endpoint = Application.get_env(:atlas, Atlas.Endpoint)

    # Start each test from a known clean slate.
    Application.delete_env(:atlas, :serve_endpoints)
    Application.delete_env(:atlas, Atlas.Endpoint)

    on_exit(fn ->
      restore(:serve_endpoints, original_global)
      restore(Atlas.Endpoint, original_endpoint)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:atlas, key)
  defp restore(key, value), do: Application.put_env(:atlas, key, value)

  # Bandit assigns an ephemeral `id: {Bandit, ref}` to each child spec
  # to allow multiple listeners. We only care that it's a Bandit spec.
  defp bandit_child_spec?(%{id: {Bandit, _ref}, start: {Bandit, :start_link, _args}}),
    do: true

  defp bandit_child_spec?(_), do: false

  describe "server?/1 (per-endpoint config)" do
    test "is false when both keys are absent" do
      refute Atlas.Endpoint.server?([])
    end

    test "is false when both keys are explicitly false" do
      Application.put_env(:atlas, :serve_endpoints, false)
      refute Atlas.Endpoint.server?(server: false)
    end

    test "is true when the per-endpoint `:server` key is true" do
      assert Atlas.Endpoint.server?(server: true)
    end

    test "is true when the global `:serve_endpoints` key is true" do
      Application.put_env(:atlas, :serve_endpoints, true)
      assert Atlas.Endpoint.server?([])
    end

    test "is true when both keys are true (OR semantics)" do
      Application.put_env(:atlas, :serve_endpoints, true)
      assert Atlas.Endpoint.server?(server: true)
    end

    test "non-boolean truthy values do not count (strict `== true`)" do
      Application.put_env(:atlas, :serve_endpoints, "true")
      refute Atlas.Endpoint.server?(server: 1)
    end
  end

  describe "server?/0 (reads `:atlas, Atlas.Endpoint`)" do
    test "is false when nothing is configured" do
      refute Atlas.Endpoint.server?()
    end

    test "is true when the global key is true" do
      Application.put_env(:atlas, :serve_endpoints, true)
      assert Atlas.Endpoint.server?()
    end

    test "is true when the per-endpoint key is true" do
      Application.put_env(:atlas, Atlas.Endpoint, server: true, port: 4400)
      assert Atlas.Endpoint.server?()
    end
  end

  describe "init/1 boot gate (child-spec inspection — no port bound)" do
    # `Atlas.Endpoint` is already running under `:atlas` for the test
    # node, so we can't `start_supervised!/1` a second copy. Instead
    # we exercise `init/1` directly and inspect the child specs it
    # returns. `Supervisor.init/2` produces `{:ok, {flags, specs}}`.

    test "returns zero children when both gate keys are absent" do
      assert {:ok, {_flags, []}} = Atlas.Endpoint.init([])
    end

    test "returns zero children when both gate keys are explicitly false" do
      Application.put_env(:atlas, :serve_endpoints, false)
      Application.put_env(:atlas, Atlas.Endpoint, server: false, port: 4400)

      assert {:ok, {_flags, []}} = Atlas.Endpoint.init([])
    end

    test "returns a Bandit child spec when the per-endpoint flag is true" do
      Application.put_env(:atlas, Atlas.Endpoint, server: true, scheme: :http, port: 4400)

      assert {:ok, {_flags, [child_spec]}} = Atlas.Endpoint.init([])
      assert bandit_child_spec?(child_spec)
    end

    test "returns a Bandit child spec when the global flag is true" do
      Application.put_env(:atlas, :serve_endpoints, true)
      Application.put_env(:atlas, Atlas.Endpoint, scheme: :http, port: 4400)

      assert {:ok, {_flags, [child_spec]}} = Atlas.Endpoint.init([])
      assert bandit_child_spec?(child_spec)
    end

    test "explicit `server: true` opt overrides absent config" do
      assert {:ok, {_flags, [child_spec]}} =
               Atlas.Endpoint.init(server: true, scheme: :http, port: 4400)

      assert bandit_child_spec?(child_spec)
    end

    test "per-endpoint opts override Application env for scheme and port" do
      Application.put_env(:atlas, Atlas.Endpoint, server: true, scheme: :http, port: 4400)

      assert {:ok, {_flags, [child_spec]}} = Atlas.Endpoint.init(port: 5500)
      # `start: {Bandit, :start_link, [bandit_opts]}`
      assert {Bandit, :start_link, [bandit_opts]} = child_spec.start
      assert Keyword.get(bandit_opts, :port) === 5500
    end
  end
end
