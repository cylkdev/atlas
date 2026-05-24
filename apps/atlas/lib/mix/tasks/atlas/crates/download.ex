defmodule Mix.Tasks.Atlas.Crates.Download do
  @shortdoc "Download a published release artifact"

  @moduledoc """
  Downloads the contents of a published release into a directory.

  By default, downloads the latest published version. Pass `--content-id` to
  download a specific publish instead.

      mix atlas.crates.download --app my_app --output ./tmp
      mix atlas.crates.download --app my_app --content-id 3F2A... --output ./tmp
  """

  use Mix.Task

  alias Atlas.Crates
  alias Mix.Atlas.Options

  @requirements ["app.start", "atlas.init"]

  @switches [app: :keep, content_id: :keep, output: :keep]
  @aliases [a: :app, o: :output]

  @impl Mix.Task
  def run(argv) do
    opts = Options.parse!(argv, @switches, @aliases)

    app = Options.fetch_one!(opts, :app)
    output = Options.fetch_one!(opts, :output)

    File.mkdir_p!(output)

    content_id = Options.fetch_one(opts, :content_id) || resolve_latest_content_id!(app)

    case Crates.download_content(app, content_id, output) do
      :ok ->
        Mix.shell().info("""
        Downloaded.
          release:    #{app}
          content_id: #{content_id}
          path:       #{Path.join(output, "release.tar.gz")}
        """)

      {:error, %ErrorMessage{} = e} ->
        Mix.raise(ErrorMessage.to_string(e))
    end
  end

  defp resolve_latest_content_id!(app) do
    case Crates.find_latest_release(app) do
      {:ok, %{content_id: nil}} ->
        Mix.raise("release #{inspect(app)} has no current content; pass --content-id")

      {:ok, %{content_id: content_id}} ->
        content_id

      {:error, %ErrorMessage{} = e} ->
        Mix.raise(ErrorMessage.to_string(e))
    end
  end
end
