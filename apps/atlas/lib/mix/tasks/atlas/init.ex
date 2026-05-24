defmodule Mix.Tasks.Atlas.Init do
  @shortdoc "Start the Atlas supervision tree and run pending migrations"

  @moduledoc """
  Ensures the `:atlas` supervision tree is running and applies any
  pending `AtlasSchemas` migrations. All Atlas mix tasks that touch the
  database or the Atlas runtime declare this task as a requirement.

      mix atlas.init

  Mix runs each `@requirements` task at most once per session, so
  declaring `"atlas.init"` in multiple tasks does not cause repeated
  starts or duplicate migrations.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    {:ok, _} = Application.ensure_all_started(:atlas)
    :ok = AtlasSchemas.Migrations.migrate()
  end
end
