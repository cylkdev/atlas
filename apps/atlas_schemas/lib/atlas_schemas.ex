defmodule AtlasSchemas do
  @moduledoc """
  Top-level namespace for the data layer.

  `atlas_schemas` owns the Ecto repo and all schema/context modules. Schema
  modules use this module to import everything they need from Ecto with a
  single line:

      defmodule AtlasSchemas.BillingAccounts.BillingAccount do
        use AtlasSchemas

        schema "billing_accounts" do
          # ...
          timestamps()
        end
      end

  `use AtlasSchemas` expands to:

      use Ecto.Schema
      @timestamp_type :utc_datetime_usec
      @timestamps_opts type: @timestamp_type
      import Ecto
      import Ecto.Changeset
      import Ecto.Query

  The `@timestamps_opts` line is the reason individual schemas never need
  to write `timestamps(type: :utc_datetime_usec)` — the type is set once
  in the macro and inherited by every schema that uses it.
  """

  @type t_res(t) :: {:ok, t} | {:error, ErrorMessage.t()}
  @type t_res(t, d) :: {:ok, t} | {:error, ErrorMessage.t(d)}

  @type id :: integer()
  @type field :: atom()
  @type params :: map()
  @type options :: keyword()

  @type aggregate :: :avg | :count | :max | :min | :sum

  @doc "When used, sets up Ecto.Schema and imports the common Ecto modules."
  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      @timestamp_type :utc_datetime_usec
      @timestamps_opts type: @timestamp_type

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end
end
