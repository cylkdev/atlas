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

# `:erlexec` (the Erlang library Atlas uses to spawn OS processes via
# `:exec`) consults the `SHELL` environment variable when it boots
# the port unless `:shell_executable` is set explicitly. In container
# / CI / systemd contexts `SHELL` is often unset, in which case
# erlexec refuses to start the port and Atlas's deploy tasks fail at
# boot. Pinning `shell_executable` here keeps Atlas boot deterministic
# regardless of the surrounding environment.
#
# erlexec is an Erlang application, so the value must be a charlist.
config :erlexec, shell_executable: ~c"/bin/sh"

config :flared,
  api_token: [{:system, "CLOUDFLARE_API_TOKEN"}],
  account_id: [{:system, "CLOUDFLARE_ACCOUNT_ID"}],
  cloudflared_dir: [{:system, "CLOUDFLARED_DIR"}, ".cloudflared"],
  executable: [{:system, "CLOUDFLARED_EXECUTABLE"}, "cloudflared"],
  tmp_dir: [{:system, "CLOUDFLARED_TMP_DIR"}],
  dns: %{ttl: 1}

config :atlas,
  mix_env: Mix.env(),
  content_backend: Atlas.Backend.S3,
  content_bucket: "atlas-artifacts",
  state_backend: Atlas.Backend.S3,
  state_bucket: "atlas-state",
  state_key: "atlas/state.json",
  oban_name: Atlas.Oban

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

  config :aws, :sandbox, enabled: true
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

config :atlas_schemas, :repo, AtlasSchemas.Repo

config :logger, :console,
  level: :debug,
  format: "$date $time [$level] $metadata$message\n",
  metadata: [:user_id]
