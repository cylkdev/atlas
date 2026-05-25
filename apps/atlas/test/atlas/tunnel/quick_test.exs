defmodule Atlas.Tunnel.QuickTest do
  use ExUnit.Case, async: true

  alias Atlas.Tunnel.Quick

  describe "extract_trycloudflare_url/1" do
    test "extracts the URL from a typical cloudflared INF line" do
      line =
        "2026-05-25T10:00:00Z INF |  https://random-words-here.trycloudflare.com |"

      assert Quick.extract_trycloudflare_url(line) ==
               "https://random-words-here.trycloudflare.com"
    end

    test "extracts when the URL is the only token on the line" do
      assert Quick.extract_trycloudflare_url("https://foo-bar-baz.trycloudflare.com") ==
               "https://foo-bar-baz.trycloudflare.com"
    end

    test "returns nil when no trycloudflare URL is present" do
      assert Quick.extract_trycloudflare_url(
               "2026-05-25T10:00:00Z INF Updated to latest version 2024.1.0"
             ) == nil
    end

    test "returns nil for an empty line" do
      assert Quick.extract_trycloudflare_url("") == nil
    end

    test "ignores HTTP (non-HTTPS) candidate URLs" do
      assert Quick.extract_trycloudflare_url("http://bad.trycloudflare.com") == nil
    end

    test "returns only the first match when several are present" do
      line =
        "first https://a.trycloudflare.com second https://b.trycloudflare.com"

      assert Quick.extract_trycloudflare_url(line) ==
               "https://a.trycloudflare.com"
    end
  end

  describe "resolve_config/1" do
    setup do
      original = Application.get_env(:atlas, Quick)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:atlas, Quick)
          value -> Application.put_env(:atlas, Quick, value)
        end
      end)

      Application.delete_env(:atlas, Quick)
      :ok
    end

    test "applies all defaults when neither config nor opts are set" do
      assert Quick.resolve_config([]) == %{
               local_url: "http://localhost:4000",
               executable: "cloudflared",
               url_timeout_ms: 30_000
             }
    end

    test "merges per-call opts on top of app env" do
      Application.put_env(:atlas, Quick,
        local_url: "http://localhost:5000",
        executable: "/usr/local/bin/cloudflared"
      )

      assert Quick.resolve_config(url_timeout_ms: 10_000) == %{
               local_url: "http://localhost:5000",
               executable: "/usr/local/bin/cloudflared",
               url_timeout_ms: 10_000
             }
    end

    test "per-call opts beat app env when both set the same key" do
      Application.put_env(:atlas, Quick, local_url: "http://localhost:5000")

      assert Quick.resolve_config(local_url: "http://localhost:9999")[:local_url] ==
               "http://localhost:9999"
    end
  end
end
