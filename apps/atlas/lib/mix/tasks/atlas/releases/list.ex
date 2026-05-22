defmodule Mix.Tasks.Atlas.Releases.List do
  @shortdoc "List release names defined in the mix project config"

  @moduledoc """
      mix atlas.releases.list
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    names =
      Mix.Project.config()
      |> Keyword.get(:releases, [])
      |> Enum.map(fn {name, _opts} -> to_string(name) end)

    if names == [] do
      Mix.shell().info("(no releases)")
    else
      Mix.shell().info(Enum.join(names, "\n"))
    end
  end
end
