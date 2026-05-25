defmodule Mix.Tasks.Atlas do
  @shortdoc "Atlas CLI entry point — pass --help to list subtasks"

  @moduledoc """
  Top-level entry point for the Atlas CLI mix tasks.

      mix atlas --help
      mix atlas -h

  Pass `--help` or `-h` to print usage and the list of available subtasks.

  ## Subtasks

    * `mix atlas.init`                   — Start Atlas and run pending migrations
    * `mix atlas.server`                 — Start Atlas with `Atlas.Endpoint` serving HTTP
                                           (use `iex -S mix atlas.server` for an interactive node)
    * `mix atlas.releases.build`         — Build an OTP release tarball via `mix release`
    * `mix atlas.releases.publish`       — Build (if needed) and upload release tarballs
    * `mix atlas.crates.list`            — List crate releases
    * `mix atlas.crates.latest`          — Show the latest published content for a release
    * `mix atlas.crates.download`        — Download a published release artifact
    * `mix atlas.crates.set`             — Point a release at a previously-uploaded version
                                           (rollback or roll-forward)
    * `mix atlas.deploy.iam_role.apply`  — Create or update the GitHub Actions OIDC deploy role
    * `mix atlas.deploy.iam_role.verify` — Verify the deploy role matches the expected policy
    * `mix atlas.workflows.deploy`       — Run the deployment workflow end-to-end
    * `mix atlas.tunnels.start`          — Start the Cloudflare tunnel for Atlas events

  Run `mix help <task>` for detailed usage of any subtask, e.g.
  `mix help atlas.releases.publish`.
  """

  use Mix.Task

  @switches [help: :boolean]
  @aliases [h: :help]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      Mix.shell().info("""
      atlas — pass --help or -h for usage.

      Run `mix atlas --help` to see the list of available subtasks.
      """)
    end
  end
end
