defmodule Mix.Tasks.Atlas.Builder.Image do
  @shortdoc "Build (and optionally push) the Atlas builder container image"

  @moduledoc """
  Builds the container image that runs Atlas deploy jobs.

  The Dockerfile lives inside this app at
  `priv/docker/builder/Dockerfile` and bakes Erlang, Elixir, Node,
  Terraform, Ansible (with the Galaxy collections from
  `priv/ansible/requirements.yml` and the pip packages from
  `priv/ansible/requirements.txt`), the AWS CLI, the AWS SSM
  session-manager-plugin, jq, sudo, unzip, curl, ca-certificates, and a
  non-root `builder` user (uid 1001, gid 1001) with passwordless sudo.
  The working directory `/workspace` is owned by `builder`.

  Because the Dockerfile and the Ansible requirements files are
  vendored under `:atlas`'s `priv` tree, this task resolves the build
  context via `Application.app_dir/2`. The task works the same whether
  `:atlas` is invoked inside this umbrella or pulled in as a Hex /
  Git dependency.

  ## Usage

      mix atlas.builder.image build
      mix atlas.builder.image build --tag ghcr.io/cylkdev/atlas-builder:latest
      mix atlas.builder.image build \\
        --tag ghcr.io/cylkdev/atlas-builder:latest \\
        --tag ghcr.io/cylkdev/atlas-builder:0.1.0 \\
        --build-arg TERRAFORM_VERSION=1.9.5 \\
        --push

  ## Switches

    * `--tag` / `-t` — One or more `name:tag` strings to apply to the
      built image (`-t` on `docker build`). Repeatable. Defaults to a
      single tag `atlas-builder:latest`.
    * `--push` — After build, run `docker push` for each `--tag`.
      Default `false`.
    * `--build-arg` — One or more `KEY=VALUE` strings forwarded as
      `--build-arg KEY=VALUE` to `docker build`. Repeatable.
    * `--builder` — The `docker`-compatible executable to invoke.
      Default `"docker"`. Useful for `podman` or a CI wrapper.

  ## Exit status

  Raises (via `Mix.raise/1`) if `docker build` or any `docker push`
  exits non-zero, so a CI step that runs this task fails the build on
  any error.
  """

  use Mix.Task

  alias Mix.Atlas.Options

  @default_tag "atlas-builder:latest"
  @default_builder "docker"

  @switches [
    tag: :keep,
    push: :boolean,
    build_arg: :keep,
    builder: :string
  ]

  @aliases [t: :tag]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {subcommand, rest} = split_subcommand(argv)

    case subcommand do
      "build" ->
        rest
        |> Options.parse!(@switches, @aliases)
        |> build()

      other ->
        Mix.raise(
          "unknown subcommand: #{inspect(other)} (expected `build`)"
        )
    end
  end

  defp split_subcommand([]),
    do: Mix.raise("missing subcommand (expected `build`)")

  defp split_subcommand([sub | rest]), do: {sub, rest}

  defp build(opts) do
    tags = opts |> Keyword.get_values(:tag) |> default_tags()
    build_args = Keyword.get_values(opts, :build_arg)
    push? = Keyword.get(opts, :push, false)
    builder = Keyword.get(opts, :builder, @default_builder)

    dockerfile = dockerfile_path()
    context = context_path()

    cmd_args =
      build_command_args(dockerfile, context, tags, build_args)

    Mix.shell().info("Running: #{builder} #{Enum.join(cmd_args, " ")}")
    run_or_raise!(builder, cmd_args)

    if push?, do: Enum.each(tags, &push!(builder, &1))

    :ok
  end

  defp push!(builder, tag) do
    Mix.shell().info("Running: #{builder} push #{tag}")
    run_or_raise!(builder, ["push", tag])
  end

  defp run_or_raise!(builder, args) do
    case System.cmd(builder, args,
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_io, 0} ->
        :ok

      {_io, code} ->
        Mix.raise(
          "#{builder} #{Enum.join(args, " ")} exited with status #{code}"
        )
    end
  end

  # --------------------------------------------------------------------
  # Helpers exposed for testability — `Mix.Tasks.Atlas.Builder.ImageTest`
  # exercises these without touching `docker`.

  @doc """
  Defaults the list of `--tag` values to a single `atlas-builder:latest`
  when no `--tag` was supplied. Otherwise returns the user-supplied tags
  in input order.
  """
  @spec default_tags([String.t()]) :: [String.t(), ...]
  def default_tags([]), do: [@default_tag]
  def default_tags(tags) when is_list(tags) and tags != [], do: tags

  @doc """
  Builds the argv that will be handed to `docker build`.

  The argument order matches the docker CLI: `build -f <dockerfile>
  <-t name:tag>... <--build-arg KEY=VALUE>... <context>`. Returned as a
  list of strings suitable for `System.cmd/3`.
  """
  @spec build_command_args(Path.t(), Path.t(), [String.t(), ...], [String.t()]) :: [String.t()]
  def build_command_args(dockerfile, context, tags, build_args) do
    ["build", "-f", dockerfile]
    |> Enum.concat(Enum.flat_map(tags, &["-t", &1]))
    |> Enum.concat(Enum.flat_map(build_args, &["--build-arg", &1]))
    |> Enum.concat([context])
  end

  @doc """
  Absolute path to the Dockerfile vendored inside `:atlas`'s `priv`
  tree. Exposed so callers (CI pipelines, ad-hoc scripts) can locate
  the file without re-implementing the lookup.
  """
  @spec dockerfile_path() :: Path.t()
  def dockerfile_path do
    Application.app_dir(:atlas, "priv/docker/builder/Dockerfile")
  end

  @doc """
  Absolute path to the Docker build context — `:atlas`'s `priv` tree.
  The context must contain `ansible/requirements.{txt,yml}` because
  the Dockerfile `COPY`s them in.
  """
  @spec context_path() :: Path.t()
  def context_path do
    Application.app_dir(:atlas, "priv")
  end
end
