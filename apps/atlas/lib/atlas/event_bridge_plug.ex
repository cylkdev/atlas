defmodule Atlas.EventBridgePlug do
  @moduledoc """
  Receives EventBridge POSTs at `POST /eventbridge`.

  Verifies the API-key header configured under
  `config :atlas, Atlas.EventBridgePlug, …` (matching the header set on
  the API destination connection at
  `deploys/terraform/eventbridge.tf:114-126`), decodes the JSON
  envelope, and routes by `source`:

    * `"aws.autoscaling"` → `Atlas.AutoScaling.handle_event/1`
    * anything else      → ignored, still acknowledged `200` so
      EventBridge does not retry.

  Response codes:
    * `200` on accepted or ignored
    * `400` on invalid JSON
    * `401` on missing/mismatched API key
    * `404` on wrong path/method
    * `500` on persistence error (EventBridge retries and eventually
      delivers to the DLQ — see `eventbridge.tf:81-86`)
  """

  @behaviour Plug

  import Plug.Conn

  @path "/eventbridge"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: @path} = conn, _opts) do
    with :ok <- verify_api_key(conn),
         {:ok, body, conn} <- read_body(conn, length: 1_000_000),
         {:ok, envelope} <- JSON.decode(body) do
      respond(conn, Atlas.AutoScaling.handle_event(envelope))
    else
      {:error, :unauthorized} ->
        send_json(conn, 401, %{status: "unauthorized"})

      {:error, _decode_error} ->
        send_json(conn, 400, %{status: "bad_request"})
    end
  end

  def call(%Plug.Conn{} = conn, _opts) do
    send_json(conn, 404, %{status: "not_found"})
  end

  defp respond(conn, {:ok, _event}), do: send_json(conn, 200, %{status: "ok"})
  defp respond(conn, :ignored), do: send_json(conn, 200, %{status: "ignored"})

  defp respond(conn, {:error, %ErrorMessage{code: :bad_request, message: message}}) do
    send_json(conn, 400, %{status: "error", message: message})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
    |> halt()
  end

  defp verify_api_key(conn) do
    cfg = Application.get_env(:atlas, __MODULE__, [])
    header_name = Keyword.fetch!(cfg, :api_key_name)
    expected = Keyword.fetch!(cfg, :api_key_value)

    with [actual] <- get_req_header(conn, String.downcase(header_name)),
         true <- Plug.Crypto.secure_compare(actual, expected) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end
end
