defmodule AtlasSchemas.Migrations.Postgres.V01 do
  @moduledoc false
  use Ecto.Migration

  def change do
    _ =
      create table(:crates) do
        add :name, :string, null: false
        add :enabled, :boolean, null: false
        add :current_version, :string
        add :current_content_id, :string

        timestamps(type: :utc_datetime_usec)
      end

    _ = create index(:crates, [:name, :current_version])
    _ = create unique_index(:crates, [:name])

    _ =
      create table(:artifacts) do
        add :version, :string, null: false
        add :content_id, :string, null: false
        add :bucket, :string, null: false
        add :key, :string, null: false
        add :etag, :string

        add :crate_id, references(:crates), null: false

        timestamps(type: :utc_datetime_usec)
      end

    _ = create index(:artifacts, [:crate_id])

    _ = create unique_index(:artifacts, [:key])
    _ = create unique_index(:artifacts, [:etag])
    _ = create unique_index(:artifacts, [:content_id])

    _ =
      create table(:auto_scaling_events) do
        add :event_id, :string, null: false
        add :source, :string, null: false
        add :detail_type, :string, null: false
        add :auto_scaling_group_name, :string, null: false
        add :lifecycle_transition, :string, null: false
        add :lifecycle_hook_name, :string
        add :lifecycle_action_token, :string
        add :ec2_instance_id, :string
        add :received_at, :utc_datetime_usec, null: false
        add :raw, :map, null: false

        timestamps(type: :utc_datetime_usec)
      end

    _ = create unique_index(:auto_scaling_events, [:event_id])
    _ = create index(:auto_scaling_events, [:auto_scaling_group_name])
    _ = create index(:auto_scaling_events, [:lifecycle_transition])

    :ok
  end
end
