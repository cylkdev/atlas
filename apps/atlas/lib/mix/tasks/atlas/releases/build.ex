defmodule Mix.Tasks.Atlas.Releases.Build do
  @shortdoc "Build OTP release tarballs"

  @moduledoc """
  Builds one or more OTP release tarballs via `mix release`. For each
  app that exposes an `assets.deploy` mix alias, that alias is run
  first so compiled assets are included in the tarball.

  Called automatically by `mix atlas.releases.publish` when a tarball
  is missing. Can also be run directly.

      mix atlas.releases.build --app my_app
      mix atlas.releases.build --app my_app --app other_app --overwrite
  """

  use Mix.Task

  alias Mix.Atlas.Options

  @switches [app: :keep, overwrite: :boolean]
  @aliases [a: :app]

  @impl Mix.Task
  def run(argv) do
    opts = Options.parse!(argv, @switches, @aliases)
    apps = Keyword.get_values(opts, :app)
    overwrite = opts[:overwrite] || false

    if apps == [] do
      Mix.raise("--app is required (e.g. mix atlas.releases.build --app my_app)")
    end

    Enum.each(apps, fn app ->
      maybe_run_assets_deploy(app)

      release_args = if overwrite, do: [app, "--overwrite"], else: [app]
      Mix.Task.run("release", release_args)
    end)
  end

  # Runs `mix assets.deploy` inside the given app's directory if that
  # alias is defined in the app's mix project config.
  defp maybe_run_assets_deploy(app) do
    app_path = Path.join([File.cwd!(), "apps", app])

    Mix.Project.in_project(String.to_atom(app), app_path, fn _module ->
      aliases = Mix.Project.config() |> Keyword.get(:aliases, [])

      if Keyword.has_key?(aliases, :"assets.deploy") do
        Mix.Task.run("assets.deploy", [])
      end
    end)
  rescue
    _ -> :ok
  end
end
