if AtlasSchemas.Config.repo() === AtlasSchemas.Repo do
  defmodule AtlasSchemas.Repo do
    @moduledoc """
    The Ecto repository for all `atlas_schemas` schemas.

    This module has one responsibility: own the connection pool to the Postgres
    database and provide the Ecto.Repo callbacks needed by `EctoShorts.Actions`.

    End-to-end use:
    - `AtlasSchemas.Application` starts this repo at boot.
    - Context modules in `atlas_schemas/<context>/` call `EctoShorts.Actions.*`.
      The repo is configured globally with `config :ecto_shorts, :repo, AtlasSchemas.Repo`,
      so context functions never pass `repo:` options.
    - Migrations under `apps/atlas_schemas/priv/repo/migrations/` run with
      `mix ecto.migrate`.

    Configuration: see `config :atlas_schemas, AtlasSchemas.Repo, ...` in the umbrella
    config files.
    """
    use Ecto.Repo,
      otp_app: :atlas_schemas,
      adapter: Ecto.Adapters.Postgres
  end
end
