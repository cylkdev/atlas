# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

config :flared,
  api_token: [{:system, "CLOUDFLARE_API_TOKEN"}],
  account_id: [{:system, "CLOUDFLARE_ACCOUNT_ID"}],
  cloudflared_dir: [{:system, "CLOUDFLARED_DIR"}, ".cloudflared"],
  executable: [{:system, "CLOUDFLARED_EXECUTABLE"}, "cloudflared"],
  tmp_dir: [{:system, "CLOUDFLARED_TMP_DIR"}],
  dns: %{ttl: 1}

config :atlas,
  content_backend: Atlas.Backend.S3,
  content_bucket: "atlas-artifacts",
  state_backend: Atlas.Backend.S3,
  state_bucket: "atlas-state",
  state_key: "atlas/state.json"

config :atlas, Atlas.Endpoint,
  scheme: :http,
  port: String.to_integer(System.get_env("ATLAS_ENDPOINT_PORT") || "4000")

config :atlas, Atlas.EventBridgePlug,
  api_key_name: System.get_env("ATLAS_EVENTBRIDGE_API_KEY_NAME") || "X-Atlas-Webhook-Key",
  api_key_value: System.get_env("ATLAS_EVENTBRIDGE_API_KEY_VALUE")

config :ex_utils, ExUtils.Strings,
  to_existing_atom: false,
  strict: true

config :aws,
  access_key_id: [
    {:awscli, {:system, "AWS_PROFILE"}, 30},
    {:awscli, "default", 30},
    {:system, "AWS_ACCESS_KEY_ID"},
    :instance_role,
    :ecs_task_role
  ],
  secret_access_key: [
    {:awscli, {:system, "AWS_PROFILE"}, 30},
    {:awscli, "default", 30},
    {:system, "AWS_SECRET_ACCESS_KEY"},
    :instance_role,
    :ecs_task_role
  ],
  security_token: [
    {:awscli, {:system, "AWS_PROFILE"}, 30},
    {:awscli, "default", 30},
    {:system, "AWS_SESSION_TOKEN"},
    :instance_role,
    :ecs_task_role
  ],
  region: [
    {:awscli, {:system, "AWS_PROFILE"}, 30},
    {:awscli, "default", 30},
    {:system, "AWS_REGION"},
    {:system, "AWS_DEFAULT_REGION"},
    "us-east-1"
  ],
  sandbox: [
    enabled: false,
    mode: :local,
    scheme: "http://",
    host: "localhost",
    port: 4566
  ]

if Mix.env() === :dev do
  config :atlas_schemas, AtlasSchemas.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "atlas_dev",
    pool_size: 10,
    show_sensitive_data_on_connection_error: true
end

if Mix.env() === :test do
  config :atlas_schemas, AtlasSchemas.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "atlas_test",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10,
    show_sensitive_data_on_connection_error: true
end

if Mix.env() === :prod do
  config :atlas_schemas, AtlasSchemas.Repo,
    username: System.get_env("PG_USERNAME") || "postgres",
    password: System.get_env("PG_PASSWORD") || "postgres",
    hostname: System.get_env("PG_HOSTNAME") || "localhost",
    database: System.get_env("PG_DATABASE") || "atlas_prod",
    pool_size: String.to_integer(System.get_env("PG_POOL_SIZE") || "10")
end

config :atlas_schemas, ecto_repos: [AtlasSchemas.Repo]

config :atlas_schemas, AtlasSchemas.Repo,
  migration_primary_key: [type: :bigserial],
  migration_timestamps: [type: :utc_datetime_usec]

config :ecto_shorts, :repo, AtlasSchemas.Repo

config :logger, :console,
  level: :debug,
  format: "$date $time [$level] $metadata$message\n",
  metadata: [:user_id]
