defmodule AtlasProvider.Protobuf do
  @moduledoc """
  https://protobuf.dev/reference/protobuf/proto3-spec
  """
  alias AtlasProvider.Casing

  @protobuf_template_path "priv/eex/protobuf.proto.eex"

  @doc """
  Returns a string that the protoc compiler would accept as valid proto3.

  ## Parameters

    * attrs - A map containing the attributes to be passed to the template.

  ## Examples

      assigns = %{
        package_name: "commerce.orders.v1",
        messages: %{
          create_order_request: %{
            customer_id: %{type: "string", field_number: 1},
            sku: %{type: "string", field_number: 2},
            quantity: %{type: "int32", field_number: 3},
            idempotency_key: %{type: "string", field_number: 4}
          },
          create_order_reply: %{
            order_id: %{type: "string", field_number: 1},
            status: %{type: "string", field_number: 2},
            total_amount_cents: %{type: "int64", field_number: 3}
          },
          get_order_request: %{
            order_id: %{type: "string", field_number: 1}
          },
          get_order_reply: %{
            order_id: %{type: "string", field_number: 1},
            customer_id: %{type: "string", field_number: 2},
            status: %{type: "string", field_number: 3},
            total_amount_cents: %{type: "int64", field_number: 4}
          },
          cancel_order_request: %{
            order_id: %{type: "string", field_number: 1},
            reason: %{type: "string", field_number: 2}
          },
          cancel_order_reply: %{
            order_id: %{type: "string", field_number: 1},
            status: %{type: "string", field_number: 2},
            cancelled: %{type: "bool", field_number: 3}
          }
        },
        services: %{
          order_service: %{
            create_order: %{
              request: "create_order_request",
              response: "create_order_reply"
            },
            get_order: %{
              request: "get_order_request",
              response: "get_order_reply"
            },
            cancel_order: %{
              request: "cancel_order_request",
              response: "cancel_order_reply"
            }
          }
        }
      }
      rendered = AtlasProvider.Protobuf.render(assigns)
      IO.puts(rendered)
  """
  def render(assigns) do
    EEx.eval_file(@protobuf_template_path, assigns: parse_assigns(assigns))
  end

  defp parse_assigns(assigns) do
    [
      messages: parse_messages(assigns.messages),
      package_name: assigns.package_name,
      services: parse_services(assigns.services)
    ]
  end

  # ---

  defp parse_services(attrs) do
    attrs
    |> Enum.map(fn {key, payload} ->
      {key |> to_string() |> Casing.to_pascal(), parse_service(payload)}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp parse_service(attrs) do
    attrs
    |> Enum.map(fn {method_key, method_spec} ->
      {method_key |> to_string() |> Casing.to_pascal(), parse_method(method_spec)}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp parse_method(%{request: request, response: response}) do
    %{
      request: request |> to_string() |> Casing.to_pascal(),
      response: response |> to_string() |> Casing.to_pascal()
    }
  end

  # ---

  defp parse_messages(attrs) do
    attrs
    |> Enum.map(fn {key, payload} ->
      {key |> to_string() |> Casing.to_pascal(), parse_message(payload)}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp parse_message(payload) do
    payload
    |> Enum.map(fn {key, value} ->
      {to_string(key), parse_message_payload(value)}
    end)
    |> Enum.sort_by(fn {_, %{field_number: n}} -> n end)
  end

  defp parse_message_payload(%{type: type, field_number: field_number})
       when is_binary(type) do
    validate_field_number!(field_number)
    %{type: type, field_number: field_number}
  end

  # Proto3 field numbers: 1..536_870_911, excluding the reserved 19_000..19_999 range.
  defp validate_field_number!(n)
       when is_integer(n) and n >= 1 and n <= 536_870_911 and
              (n < 19_000 or n > 19_999) do
    :ok
  end

  defp validate_field_number!(n) do
    raise ArgumentError,
          "field_number must be an integer in 1..536_870_911 excluding 19_000..19_999, got: #{inspect(n)}"
  end
end
