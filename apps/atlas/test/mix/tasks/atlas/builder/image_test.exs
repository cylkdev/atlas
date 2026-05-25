defmodule Mix.Tasks.Atlas.Builder.ImageTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atlas.Builder.Image

  describe "default_tags/1" do
    test "defaults to atlas-builder:latest when no --tag was supplied" do
      assert Image.default_tags([]) == ["atlas-builder:latest"]
    end

    test "preserves user-supplied tags in input order" do
      assert Image.default_tags(["a:1", "b:2"]) == ["a:1", "b:2"]
    end
  end

  describe "build_command_args/4" do
    test "emits `build -f <dockerfile> -t <tag> <context>` for a single tag" do
      assert Image.build_command_args(
               "/abs/Dockerfile",
               "/abs/ctx",
               ["atlas-builder:latest"],
               []
             ) == [
               "build",
               "-f",
               "/abs/Dockerfile",
               "-t",
               "atlas-builder:latest",
               "/abs/ctx"
             ]
    end

    test "interleaves multiple `-t` pairs in the order they were given" do
      args =
        Image.build_command_args(
          "/abs/Dockerfile",
          "/abs/ctx",
          ["registry/image:latest", "registry/image:0.1.0"],
          []
        )

      assert args == [
               "build",
               "-f",
               "/abs/Dockerfile",
               "-t",
               "registry/image:latest",
               "-t",
               "registry/image:0.1.0",
               "/abs/ctx"
             ]
    end

    test "appends each --build-arg as a `--build-arg KEY=VALUE` pair" do
      args =
        Image.build_command_args(
          "/abs/Dockerfile",
          "/abs/ctx",
          ["atlas-builder:latest"],
          ["TERRAFORM_VERSION=1.9.5", "NODE_MAJOR=20"]
        )

      assert args == [
               "build",
               "-f",
               "/abs/Dockerfile",
               "-t",
               "atlas-builder:latest",
               "--build-arg",
               "TERRAFORM_VERSION=1.9.5",
               "--build-arg",
               "NODE_MAJOR=20",
               "/abs/ctx"
             ]
    end

    test "places the build context as the final positional argument" do
      args =
        Image.build_command_args(
          "/abs/Dockerfile",
          "/abs/ctx",
          ["t:1", "t:2"],
          ["A=1"]
        )

      assert List.last(args) == "/abs/ctx"
    end
  end

  describe "dockerfile_path/0 and context_path/0" do
    test "dockerfile_path/0 ends with priv/docker/builder/Dockerfile" do
      assert String.ends_with?(
               Image.dockerfile_path(),
               Path.join(["priv", "docker", "builder", "Dockerfile"])
             )
    end

    test "context_path/0 ends with the priv directory" do
      assert String.ends_with?(Image.context_path(), "priv")
    end

    test "dockerfile_path/0 is anchored under context_path/0" do
      ctx = Image.context_path()
      assert String.starts_with?(Image.dockerfile_path(), ctx)
    end
  end

  describe "run/1 input validation" do
    test "raises a Mix error on empty argv" do
      assert_raise Mix.Error, ~r/missing subcommand/, fn ->
        Image.run([])
      end
    end

    test "raises a Mix error on an unknown subcommand" do
      assert_raise Mix.Error, ~r/unknown subcommand/, fn ->
        Image.run(["bake"])
      end
    end
  end
end
