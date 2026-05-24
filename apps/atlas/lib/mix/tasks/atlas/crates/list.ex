defmodule Mix.Tasks.Atlas.Crates.List do
  @shortdoc "List crate releases"

  @moduledoc """
      mix atlas.crates.list
      mix atlas.crates.list --enabled-only --limit 25
  """

  use Mix.Task

  alias Mix.Atlas.Options
  alias AtlasSchemas.Crates

  @requirements ["app.start", "atlas.init"]

  @switches [limit: [:integer, :keep], enabled_only: :boolean]
  @aliases [l: :limit]

  @impl Mix.Task
  def run(argv) do
    opts = Options.parse!(argv, @switches, @aliases)

    limit = Options.fetch_one(opts, :limit, 50)

    params =
      %{}
      |> Map.put(:last, limit)
      |> maybe_put(:enabled, if(opts[:enabled_only], do: true))

    crates = Crates.list_crates(params)

    if crates == [] do
      Mix.shell().info("(no crates)")
    else
      header = "NAME\tVERSION\tCONTENT_ID\tENABLED\tUPDATED_AT"

      rows =
        Enum.map(crates, fn r ->
          Enum.join(
            [
              r.name,
              r.current_version || "-",
              r.current_content_id || "-",
              to_string(r.enabled),
              to_string(r.updated_at)
            ],
            "\t"
          )
        end)

      Mix.shell().info(Enum.join([header | rows], "\n"))
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
