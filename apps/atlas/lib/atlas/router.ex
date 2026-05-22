defmodule Atlas.Router do
  @moduledoc """
  Top-level HTTP plug. Dispatches by path:

    * `POST /eventbridge`              → `Atlas.EventBridgePlug`
    * `GET  /crates/:name/latest`      → latest published artifact for the
                                          given crate (release group)
    * anything else                    → `404`
  """

  @behaviour Plug

  import Plug.Conn

  @routes %{
    "/health_check" => Atlas.Controllers.HealthCheckController,
    "/eventbridge" => Atlas.Controllers.EventBridgeController,
    "/crates/:name/latest" => Atlas.Controllers.CrateController
  }

  def routes, do: @routes

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: "/eventbridge"} = conn, opts) do
    Atlas.EventBridgePlug.call(conn, Atlas.EventBridgePlug.init(opts))
  end

  def call(%Plug.Conn{method: "GET", path_info: ["crates", name, "latest"]} = conn, _opts) do
    case Atlas.Crates.find_latest_release(name) do
      {:ok, %{content_id: nil}} ->
        send_json(conn, 404, %{status: "not_found", crate: name})

      {:ok, latest} ->
        send_json(conn, 200, Map.put(latest, :name, name))

      {:error, %{code: :not_found}} ->
        send_json(conn, 404, %{status: "not_found", crate: name})

      {:error, error} ->
        send_json(conn, 500, %{status: "error", message: inspect(error)})
    end
  end

  def call(%Plug.Conn{} = conn, _opts) do
    send_json(conn, 404, %{status: "not_found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
    |> halt()
  end
end
