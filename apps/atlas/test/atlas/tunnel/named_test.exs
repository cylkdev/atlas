defmodule Atlas.Tunnel.NamedTest do
  use ExUnit.Case, async: false

  alias Atlas.Tunnel.Named

  setup do
    original = Application.get_env(:atlas, Named)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:atlas, Named)
        value -> Application.put_env(:atlas, Named, value)
      end
    end)

    Application.delete_env(:atlas, Named)
    :ok
  end

  describe "url_for/1" do
    test "produces an https:// URL from a bare hostname" do
      assert Named.url_for("atlas-events.cylk.dev") ==
               "https://atlas-events.cylk.dev"
    end
  end

  describe "resolve_config/1" do
    test "returns {:error, {:missing_key, :token}} when token is not configured" do
      Application.put_env(:atlas, Named, hostname: "atlas-events.cylk.dev")

      assert Named.resolve_config([]) ==
               {:error, {:missing_key, :token}}
    end

    test "returns {:error, {:missing_key, :hostname}} when hostname is not configured" do
      Application.put_env(:atlas, Named, token: "tok123")

      assert Named.resolve_config([]) ==
               {:error, {:missing_key, :hostname}}
    end

    test "rejects an empty-string token as missing" do
      Application.put_env(:atlas, Named, token: "", hostname: "h.example.com")

      assert Named.resolve_config([]) ==
               {:error, {:missing_key, :token}}
    end

    test "merges defaults for tunnel_name and service when both required keys are present" do
      Application.put_env(:atlas, Named,
        token: "tok123",
        hostname: "atlas-events.cylk.dev"
      )

      assert {:ok, config} = Named.resolve_config([])

      assert config[:tunnel_name] == "atlas-events"
      assert config[:hostname] == "atlas-events.cylk.dev"
      assert config[:token] == "tok123"

      assert config[:routes] == [
               %{hostname: "atlas-events.cylk.dev", service: "http://localhost:4000"}
             ]
    end

    test "per-call opts override app env" do
      Application.put_env(:atlas, Named,
        token: "tok-env",
        hostname: "env.example.com"
      )

      assert {:ok, config} =
               Named.resolve_config(token: "tok-call", hostname: "call.example.com")

      assert config[:token] == "tok-call"
      assert config[:hostname] == "call.example.com"
    end

    test "tunnel_name override is honored" do
      Application.put_env(:atlas, Named,
        token: "tok123",
        hostname: "x.example.com",
        tunnel_name: "my-custom-tunnel"
      )

      assert {:ok, config} = Named.resolve_config([])
      assert config[:tunnel_name] == "my-custom-tunnel"
    end

    test "service URL is composed from scheme + service_domain + service_port" do
      Application.put_env(:atlas, Named,
        token: "tok123",
        hostname: "x.example.com",
        scheme: :https,
        service_domain: "127.0.0.1",
        service_port: 4443
      )

      assert {:ok, config} = Named.resolve_config([])
      assert config[:routes] == [%{hostname: "x.example.com", service: "https://127.0.0.1:4443"}]
    end
  end
end
