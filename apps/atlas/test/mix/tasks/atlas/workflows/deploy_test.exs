defmodule Mix.Tasks.Atlas.Workflows.DeployTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Atlas.Workflows.Deploy

  setup do
    original = Application.get_env(:atlas, :tunnel)
    Atlas.Tunnel.Stub.reset()
    Application.put_env(:atlas, :tunnel, Atlas.Tunnel.Stub)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:atlas, :tunnel)
        value -> Application.put_env(:atlas, :tunnel, value)
      end
    end)

    :ok
  end

  describe "with_tunnel/1" do
    test "calls start_link, url, and stop in that order" do
      Deploy.with_tunnel(fn -> :ok end)

      assert [
               {:start_link, _opts},
               {:url, _url},
               :stop
             ] = Atlas.Tunnel.Stub.events()
    end

    test "returns the value returned by fun" do
      result = Deploy.with_tunnel(fn -> {:ok, 42} end)
      assert result == {:ok, 42}
    end

    test "logs the URL returned by the backend" do
      Atlas.Tunnel.Stub.set_url("https://test.trycloudflare.com")
      Deploy.with_tunnel(fn -> :ok end)

      assert {:url, "https://test.trycloudflare.com"} in Atlas.Tunnel.Stub.events()
    end

    test "stops the tunnel even when fun raises" do
      assert_raise RuntimeError, "boom", fn ->
        Deploy.with_tunnel(fn -> raise "boom" end)
      end

      assert :stop in Atlas.Tunnel.Stub.events()
    end

    test "stops the tunnel even when fun calls exit/1" do
      catch_exit(Deploy.with_tunnel(fn -> exit({:shutdown, 1}) end))

      assert :stop in Atlas.Tunnel.Stub.events()
    end
  end
end
