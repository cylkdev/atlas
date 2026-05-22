defmodule AtlasSchemas.Crates.Crate do
  use AtlasSchemas

  @required_fields [
    :name
  ]

  @allowed_fields @required_fields ++
                    [
                      :current_version,
                      :current_content_id,
                      :enabled
                    ]

  schema "crates" do
    field :name, :string
    field :enabled, :boolean, default: false
    field :current_version, :string
    field :current_content_id, :string

    has_many :artifacts, AtlasSchemas.Crates.Artifact

    timestamps()
  end

  def changeset(struct, params) do
    struct
    |> cast(params, @allowed_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
    |> unique_constraint(:current_content_id)
    |> EctoShorts.CommonChanges.preload_change_assoc(:artifacts)
  end
end
