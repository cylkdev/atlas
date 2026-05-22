defmodule Atlas.HealthCheckPlug do
  @moduledoc """
  Endpoint-level health probe.

  Mounted on the endpoint pipeline before session, parsers, and the router so
  that the load balancer's frequent `GET /health_check` does not pay that cost
  on every hit. Any other request passes straight through.
  """

  @behaviour Plug

  import Plug.Conn

  @default_path "/health_check"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: request_path} = conn, opts) do
    match_path = get_path(opts)

    case request_path do
      ^match_path ->
        conn
        |> send_resp(200, get_response(conn, opts))
        |> halt()

      _ ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp get_path(opts) do
    opts[:path] || config()[:path] || @default_path
  end

  defp get_response(conn, opts) do
    case opts[:response] || config()[:response] do
      nil -> %{"status" => "OK"}
      {mod, fun} -> apply(mod, fun, [conn])
      fun when is_function(fun) -> fun.(conn)
    end
  end

  defp config do
    Application.get_env(:atlas, :health_check, [])
  end
end
