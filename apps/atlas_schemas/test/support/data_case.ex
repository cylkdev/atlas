defmodule AtlasSchemas.DataCase do
  @moduledoc """
  Test case template for `atlas_schemas` tests that hit the database.

  Sets up an `Ecto.Adapters.SQL.Sandbox` connection per test so tests run
  in isolated transactions and roll back on completion.

  Use it in a test module by writing `use AtlasSchemas.DataCase` at the top.
  Pass `async: true` if the test does not depend on shared mutable state
  outside of the database.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias AtlasSchemas.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import AtlasSchemas.DataCase
    end
  end

  setup tags do
    AtlasSchemas.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Checks out a sandbox connection for the current test process.

  Arguments:
  - `tags` (map): the ExUnit tag map. When it contains `async: true`, the
    sandbox is set to `:auto` shared mode for the calling process.

  Returns:
  - `:ok`.

  ## Examples

      iex> AtlasSchemas.DataCase.setup_sandbox(%{async: true})
      :ok
  """
  @spec setup_sandbox(map()) :: :ok
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AtlasSchemas.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
