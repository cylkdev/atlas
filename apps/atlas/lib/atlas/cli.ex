defmodule Atlas.CLI do
  @moduledoc """
  Escript entry point for the `atlas` binary.

  Translates space-separated subcommands into the matching `Mix.Tasks.Atlas.*`
  task and shells out to `mix`. Must be run from inside the umbrella checkout so
  that `mix` can resolve the project.

      atlas crates build --app atlas --overwrite
      # equivalent to: mix atlas.releases.build --app atlas --overwrite
  """

  @mix_executable "mix"

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    argv
    |> split_command()
    |> dispatch()
  end

  @doc false
  @spec split_command([String.t()]) ::
          {:ok, String.t(), [String.t()]} | {:error, :no_command} | {:help, :top}
  def split_command([]), do: {:error, :no_command}
  def split_command(["--help"]), do: {:help, :top}
  def split_command(["-h"]), do: {:help, :top}

  def split_command(argv) do
    {segments, rest} = Enum.split_while(argv, &(not String.starts_with?(&1, "-")))

    case segments do
      [] -> {:error, :no_command}
      _ -> {:ok, Enum.join(segments, "."), rest}
    end
  end

  @spec dispatch({:ok, String.t(), [String.t()]} | {:error, :no_command} | {:help, :top}) ::
          no_return()
  defp dispatch({:ok, task_suffix, rest}) do
    run_mix("atlas.#{task_suffix}", rest)
  end

  defp dispatch({:help, :top}) do
    IO.puts(usage())
    System.halt(0)
  end

  defp dispatch({:error, :no_command}) do
    IO.puts(:stderr, "error: no command given\n")
    IO.puts(:stderr, usage())
    System.halt(1)
  end

  @spec run_mix(String.t(), [String.t()]) :: no_return()
  defp run_mix(task, argv) do
    {_collector, status} =
      System.cmd(@mix_executable, [task | argv],
        stderr_to_stdout: true,
        into: IO.stream(:stdio, :line)
      )

    System.halt(status)
  end

  defp usage do
    """
    Usage:
      atlas <namespace> <command> [flags...]

    Examples:
      atlas crates build --app my_app --overwrite
      atlas crates list
      atlas crates publish --app my_app

    Each invocation is forwarded to `mix atlas.<namespace>.<command>` with
    the remaining flags. Run from inside the atlas_umbrella checkout.
    """
  end
end
