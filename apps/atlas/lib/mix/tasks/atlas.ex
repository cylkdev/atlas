defmodule Mix.Tasks.Atlas do
  @shortdoc "Atlas CLI entry point — pass --help to list subtasks"

  @moduledoc """
  Top-level entry point for the Atlas CLI mix tasks.

      mix atlas --help
      mix atlas -h

  Pass `--help` or `-h` to print usage and the list of available subtasks.

  ## Subtasks

    * `mix atlas.releases.build`     — Build an OTP release tarball via `mix release`
    * `mix atlas.crates.publish`   — Release and upload one or more apps
    * `mix atlas.crates.list`      — List crate releases
    * `mix atlas.crates.latest`    — Show the latest published content for a release
    * `mix atlas.crates.download`  — Download a published release artifact
    * `mix atlas.crates.set`       — Point a release at a previously-uploaded version
                                         (rollback or roll-forward)

  Run `mix help <task>` for detailed usage of any subtask, e.g.
  `mix help atlas.crates.publish`.
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
