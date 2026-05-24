import Config

config :atlas, Atlas.Endpoint,
  scheme: :http,
  port: String.to_integer(System.get_env("ATLAS_ENDPOINT_PORT") || "4000")

config :atlas, Atlas.EventBridgePlug,
  api_key_name: System.get_env("ATLAS_EVENTBRIDGE_API_KEY_NAME") || "X-Atlas-Webhook-Key",
  api_key_value: System.get_env("ATLAS_EVENTBRIDGE_API_KEY_VALUE")
