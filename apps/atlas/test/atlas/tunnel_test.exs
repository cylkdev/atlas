defmodule Atlas.TunnelTest do
  use ExUnit.Case, async: false

  alias Atlas.Tunnel

  setup do
    original = Application.get_env(:atlas, :tunnel)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:atlas, :tunnel)
        value -> Application.put_env(:atlas, :tunnel, value)
      end
    end)

    :ok
  end

  describe "backend/0" do
    test "defaults to Atlas.Tunnel.Named when :atlas, :tunnel is unset" do
      Application.delete_env(:atlas, :tunnel)
      assert Tunnel.backend() == Atlas.Tunnel.Named
    end

    test "maps :named to Atlas.Tunnel.Named" do
      Application.put_env(:atlas, :tunnel, :named)
      assert Tunnel.backend() == Atlas.Tunnel.Named
    end

    test "maps :quick to Atlas.Tunnel.Quick" do
      Application.put_env(:atlas, :tunnel, :quick)
      assert Tunnel.backend() == Atlas.Tunnel.Quick
    end

    test "maps :none to Atlas.Tunnel.Noop" do
      Application.put_env(:atlas, :tunnel, :none)
      assert Tunnel.backend() == Atlas.Tunnel.Noop
    end

    test "passes through any explicit module name" do
      Application.put_env(:atlas, :tunnel, Atlas.Tunnel.Stub)
      assert Tunnel.backend() == Atlas.Tunnel.Stub
    end

    test "raises ArgumentError for an invalid non-atom config value" do
      Application.put_env(:atlas, :tunnel, "named")

      assert_raise ArgumentError, ~r/invalid :atlas, :tunnel config value/, fn ->
        Tunnel.backend()
      end
    end
  end

  describe "start_link/1, url/1, stop/1 delegate to the configured backend" do
    setup do
      Atlas.Tunnel.Stub.reset()
      Application.put_env(:atlas, :tunnel, Atlas.Tunnel.Stub)
      :ok
    end

    test "the dispatcher emits one start_link, one url, one stop in order" do
      {:ok, pid} = Tunnel.start_link([])
      assert {:ok, _url} = Tunnel.url(pid)
      assert :ok = Tunnel.stop(pid)

      events = Atlas.Tunnel.Stub.events()

      assert [
               {:start_link, _},
               {:url, _},
               :stop
             ] = events
    end

    test "url/1 returns the stub's preconfigured URL" do
      Atlas.Tunnel.Stub.set_url("https://example.trycloudflare.com")

      {:ok, pid} = Tunnel.start_link([])
      assert Tunnel.url(pid) == {:ok, "https://example.trycloudflare.com"}
      Tunnel.stop(pid)
    end
  end
end
