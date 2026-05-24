defmodule Mix.Tasks.Atlas.Releases.Publish do
  @shortdoc "Publish prebuilt release tarballs to S3 via the Crates API"

  @moduledoc """
  Publishes the release tarballs produced by `mix atlas.releases.build` to S3
  via `Atlas.Crates`. Resolves the set of releases from `:releases` in the
  umbrella `mix.exs` (or from one or more `--app` flags), then looks up each
  tarball at the deterministic path `_build/<env>/<name>-<version>.tar.gz`.

  If every tarball already exists, they are uploaded as-is. If any are
  missing, `mix atlas.releases.build --overwrite` is invoked once for the
  full requested set before publishing.

      mix atlas.releases.publish
      mix atlas.releases.publish --app my_app
      mix atlas.releases.publish --app my_app --app other_app
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

    apps =
      case Keyword.get_values(opts, :app) do
        [] -> release_apps()
        list -> list
      end

    releases = Enum.map(apps, &resolve_release/1)

    ensure_tarballs!(releases, apps)

    Enum.each(releases, &publish_release/1)
  end

  defp release_apps do
    Mix.Project.config()
    |> Keyword.get(:releases, [])
    |> Keyword.keys()
    |> Enum.map(&to_string/1)
  end

  defp resolve_release(app) do
    release =
      app
      |> String.to_atom()
      |> Mix.Release.from_config!(Mix.Project.config(), [])

    name = to_string(release.name)
    version = release.version
    path = Path.join(Mix.Project.build_path(), "#{name}-#{version}.tar.gz")
    %{name: name, version: version, path: path}
  end

  defp ensure_tarballs!(releases, apps) do
    if Enum.any?(releases, &(not File.exists?(&1.path))) do
      build_argv = Enum.flat_map(apps, &["--app", &1]) ++ ["--overwrite"]
      Mix.Task.reenable("atlas.releases.build")
      Mix.Task.run("atlas.releases.build", build_argv)

      missing = Enum.filter(releases, &(not File.exists?(&1.path)))

      if missing !== [] do
        Mix.raise("tarballs missing after build: " <> Enum.map_join(missing, ", ", & &1.path))
      end
    end
  end

  defp publish_release(%{name: name, version: version, path: path}) do
    Mix.shell().info("==> publishing #{name} (version: #{version})")

    {:ok, crate} = Crates.create_crate(name, version)

    blob = File.read!(path)
    {:ok, %{artifact: artifact}} = Crates.publish_content(crate, blob, version)

    Mix.shell().info("""
    Published.
      crate:      #{crate.name}
      version:    #{artifact.version}
      content_id: #{artifact.content_id}
      key:        #{artifact.key}
    """)
  end
end
