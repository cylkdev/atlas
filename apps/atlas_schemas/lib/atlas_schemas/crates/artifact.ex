defmodule AtlasSchemas.Crates.Artifact do
  use AtlasSchemas

  @required_fields [
    :content_id,
    :bucket,
    :key,
    :etag,
    :version
  ]

  @allowed_fields @required_fields ++ [:crate_id]

  schema "artifacts" do
    field :version, :string
    field :content_id, :string
    field :bucket, :string
    field :key, :string
    field :etag, :string

    belongs_to :crate, AtlasSchemas.Crates.Crate

    timestamps()
  end

  def changeset(struct, params) do
    struct
    |> cast(params, @allowed_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:content_id)
    |> unique_constraint(:key)
    |> unique_constraint(:etag)
    |> EctoShorts.CommonChanges.preload_change_assoc(:crate,
      required_when_missing: :crate_id
    )
  end
end
