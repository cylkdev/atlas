defmodule Atlas.CLITest do
  use ExUnit.Case, async: true

  alias Atlas.CLI

  describe "split_command/1" do
    test "empty argv → :no_command" do
      assert CLI.split_command([]) == {:error, :no_command}
    end

    test "--help and -h → top-level help" do
      assert CLI.split_command(["--help"]) == {:help, :top}
      assert CLI.split_command(["-h"]) == {:help, :top}
    end

    test "single positional becomes the task suffix" do
      assert CLI.split_command(["crates"]) == {:ok, "crates", []}
    end

    test "namespace + command join with a dot" do
      assert CLI.split_command(["crates", "build"]) == {:ok, "releases.build", []}
    end

    test "flags after the command are forwarded verbatim" do
      assert CLI.split_command(["crates", "build", "--app", "atlas", "--overwrite"]) ==
               {:ok, "releases.build", ["--app", "atlas", "--overwrite"]}
    end

    test "first dashed token terminates the command segments" do
      assert CLI.split_command(["crates", "--app", "atlas", "build"]) ==
               {:ok, "crates", ["--app", "atlas", "build"]}
    end

    test "leading flag with no command → :no_command" do
      assert CLI.split_command(["--app", "atlas"]) == {:error, :no_command}
    end
  end
end
