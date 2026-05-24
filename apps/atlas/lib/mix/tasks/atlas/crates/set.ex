defmodule Mix.Tasks.Atlas.Crates.Set do
  @shortdoc "Point a release at a previously-uploaded version (rollback or roll-forward)"

  @moduledoc """
  Updates a release so that its current version points at a version that has
  already been uploaded. Useful for rolling back to an earlier publish.

      mix atlas.crates.set --app my_app --version 0.1.0
  """

  use Mix.Task

  alias Atlas.Crates
  alias Mix.Atlas.Options

  @requirements ["app.start", "atlas.init"]

  @switches [app: :keep, version: :keep]
  @aliases [a: :app, v: :version]

  @impl Mix.Task
  def run(argv) do
    opts = Options.parse!(argv, @switches, @aliases)

    app = Options.fetch_one!(opts, :app)
    version = Options.fetch_one!(opts, :version)

    with {:ok, crate} <- Crates.find_crate_by_name(app),
         {:ok, %{crate: crate}} <- Crates.set_current_release_to_version(crate, version) do
      Mix.shell().info("""
      Current version updated.
        crate:      #{crate.name}
        version:    #{crate.current_version}
        content_id: #{crate.current_content_id}
      """)
    else
      {:error, %ErrorMessage{} = e} ->
        Mix.raise(ErrorMessage.to_string(e))
    end
  end
end
