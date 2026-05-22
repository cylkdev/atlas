defmodule AtlasSchemas.AutoScaling.Event do
  use AtlasSchemas

  @type t :: %__MODULE__{}

  @required_fields [
    :event_id,
    :source,
    :detail_type,
    :auto_scaling_group_name,
    :lifecycle_transition,
    :received_at,
    :raw
  ]

  @allowed_fields @required_fields ++
                    [
                      :lifecycle_hook_name,
                      :lifecycle_action_token,
                      :ec2_instance_id
                    ]

  schema "auto_scaling_events" do
    field :event_id, :string
    field :source, :string
    field :detail_type, :string
    field :auto_scaling_group_name, :string
    field :lifecycle_transition, :string
    field :lifecycle_hook_name, :string
    field :lifecycle_action_token, :string
    field :ec2_instance_id, :string
    field :received_at, :utc_datetime_usec
    field :raw, :map

    timestamps()
  end

  def changeset(struct, params) do
    struct
    |> cast(params, @allowed_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:event_id)
  end
end
