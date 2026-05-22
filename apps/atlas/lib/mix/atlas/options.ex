defmodule Mix.Atlas.Options do
  @moduledoc false

  def parse!(argv, switches, aliases \\ []) do
    case OptionParser.parse(argv, strict: switches, aliases: aliases) do
      {opts, [], []} ->
        opts

      {_opts, _, [{flag, _} | _]} ->
        Mix.raise("unrecognized flag: #{flag} (run `mix help <task>` for usage)")

      {_opts, [arg | _], _} ->
        Mix.raise("unexpected positional argument: #{inspect(arg)}")
    end
  end

  def fetch_one!(opts, key) do
    case Keyword.get_values(opts, key) do
      [v] -> v
      [] -> Mix.raise("--#{flag(key)} is required")
      _ -> Mix.raise("--#{flag(key)} may only be passed once")
    end
  end

  def fetch_one(opts, key, default \\ nil) do
    case Keyword.get_values(opts, key) do
      [] -> default
      [v] -> v
      _ -> Mix.raise("--#{flag(key)} may only be passed once")
    end
  end

  defp flag(key), do: key |> Atom.to_string() |> String.replace("_", "-")
end
