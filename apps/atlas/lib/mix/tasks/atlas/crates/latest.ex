defmodule Mix.Tasks.Atlas.Crates.Latest do
  @shortdoc "Show the latest published content for a release"

  @moduledoc """
      mix atlas.crates.latest --app my_app
  """

  use Mix.Task

  alias Atlas.Crates
  alias Mix.Atlas.Options

  @requirements ["app.start", "atlas.init"]

  @switches [app: :keep]
  @aliases [a: :app]

  @impl Mix.Task
  def run(argv) do
    opts = Options.parse!(argv, @switches, @aliases)
    app = Options.fetch_one!(opts, :app)

    case Crates.find_latest_release(app) do
      {:ok, %{content_id: nil}} ->
        Mix.raise("release #{inspect(app)} has no current content")

      {:ok, %{content_id: content_id, version: version, bucket: bucket, key: key}} ->
        Mix.shell().info("""
        release:    #{app}
        version:    #{version}
        content_id: #{content_id}
        bucket:     #{bucket}
        key:        #{key}
        """)

      {:error, %ErrorMessage{} = e} ->
        Mix.raise(ErrorMessage.to_string(e))
    end
  end
end
