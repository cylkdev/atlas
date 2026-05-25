defmodule Mix.Tasks.Atlas.Deploy.Init do
  @shortdoc "Prepare a deploy host to run `mix atlas.workflows.deploy`"

  @moduledoc """
  Single entry point that prepares a Linux deploy host for the rest
  of Atlas's deploy tasks.

  On invocation this task:

    1. Runs `mix deps.compile erlexec` so the SUID `exec-port` binary
       (under `deps/erlexec/priv/<arch>/exec-port`) exists on disk.
       Atlas's `:exec` integration requires that binary at runtime.
    2. Invokes the vendored shell script
       `priv/scripts/setup-erlexec-sudoers.sh` to install
       `/etc/sudoers.d/erlexec`, granting the named local user
       passwordless sudo on the `exec-port` binary specifically (and
       nothing else). The script validates the resulting sudoers entry
       with `visudo -c` and rolls back on failure.

  Subsequent host-bootstrap concerns extend this task rather than
  adding new mix tasks.

  ## Usage

      sudo mix atlas.deploy.init --user builder

  ## Switches

    * `--user` — Required. The local Unix account that will run
      `mix atlas.workflows.deploy` and therefore needs sudo on
      `exec-port`.
    * `--erlexec-priv` — Optional. Override the directory under which
      to look for `<arch>/exec-port`. Defaults to
      `deps/erlexec/priv` relative to the project root.
    * `--sudoers-file` — Optional. Path of the sudoers file the script
      should write. Defaults to `/etc/sudoers.d/erlexec`. Useful for
      testing on a host where you do not want to touch the real
      sudoers tree.
    * `--script` — Optional. Path of the setup script. Defaults to the
      vendored copy resolved via `Application.app_dir(:atlas,
      "priv/scripts/setup-erlexec-sudoers.sh")`.
    * `--skip-compile` — Optional boolean. Skip step 1 (the
      `mix deps.compile erlexec` invocation). Use this when the binary
      already exists and you only want to refresh sudoers. Default
      `false`.

  ## Exit status

  Raises (via `Mix.raise/1`) if any step fails. Exit codes from the
  shell script are surfaced verbatim in the failure message.
  """

  use Mix.Task

  alias Mix.Atlas.Options

  @default_erlexec_priv "deps/erlexec/priv"
  @port_basename "exec-port"

  @switches [
    user: :string,
    erlexec_priv: :string,
    sudoers_file: :string,
    script: :string,
    skip_compile: :boolean
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    opts = Options.parse!(argv, @switches)

    user = opts[:user] || Mix.raise("--user is required")
    erlexec_priv = Keyword.get(opts, :erlexec_priv, @default_erlexec_priv)
    script = Keyword.get(opts, :script, default_script_path())
    sudoers_file = Keyword.get(opts, :sudoers_file)
    skip_compile? = Keyword.get(opts, :skip_compile, false)

    unless skip_compile? do
      Mix.shell().info("==> mix deps.compile erlexec")
      Mix.Task.run("deps.compile", ["erlexec"])
    end

    binary = find_exec_port!(erlexec_priv)

    script_args = build_script_args(user, binary, sudoers_file)

    Mix.shell().info(
      "==> #{script} #{Enum.join(script_args, " ")}"
    )

    run_or_raise!(script, script_args)

    :ok
  end

  # --------------------------------------------------------------------
  # Helpers exposed for testability — exercised by
  # `Mix.Tasks.Atlas.Deploy.InitTest` without touching the real shell
  # script or compiling erlexec.

  @doc """
  Builds the argv handed to the setup script. Always includes
  `--user <user>` and `--binary <binary>`; appends `--file <file>` only
  when the caller supplied a custom sudoers destination.
  """
  @spec build_script_args(String.t(), Path.t(), Path.t() | nil) :: [String.t()]
  def build_script_args(user, binary, nil) do
    ["--user", user, "--binary", binary]
  end

  def build_script_args(user, binary, sudoers_file) do
    ["--user", user, "--binary", binary, "--file", sudoers_file]
  end

  @doc """
  Locates the erlexec `exec-port` binary under `<priv>/<arch>/exec-port`.

  Searches every immediate subdirectory of `priv` for a regular file
  named `exec-port`. erlexec's build process creates exactly one such
  subdirectory keyed by the build host's `:erlang.system_info(:system_architecture)`
  triple (e.g. `aarch64-apple-darwin24.5.0`, `x86_64-pc-linux-gnu`).

  Returns the absolute path on success. Raises a `Mix.Error` with a
  helpful message when zero or more than one match is found.
  """
  @spec find_exec_port!(Path.t()) :: Path.t()
  def find_exec_port!(priv_dir) do
    case list_exec_ports(priv_dir) do
      [single] ->
        single

      [] ->
        Mix.raise(
          "could not find #{@port_basename} under #{priv_dir}. " <>
            "Run `mix deps.compile erlexec` first, or pass " <>
            "--erlexec-priv to override the search root."
        )

      multiple ->
        Mix.raise(
          "found multiple #{@port_basename} binaries under #{priv_dir}: " <>
            Enum.join(multiple, ", ") <>
            ". Remove the stale build directory and re-run this task."
        )
    end
  end

  @doc """
  Returns every absolute path matching `<priv>/<arch>/exec-port`.
  Used by `find_exec_port!/1`; exposed as its own function so tests
  can assert on the list without going through the raising wrapper.
  """
  @spec list_exec_ports(Path.t()) :: [Path.t()]
  def list_exec_ports(priv_dir) do
    case File.ls(priv_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join([priv_dir, &1, @port_basename]))
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.expand/1)

      {:error, _} ->
        []
    end
  end

  @doc """
  Absolute path of the vendored shell script. Resolved via
  `Application.app_dir/2` so the task locates the script the same way
  whether `:atlas` is in this umbrella or a dependency.
  """
  @spec default_script_path() :: Path.t()
  def default_script_path do
    Application.app_dir(:atlas, "priv/scripts/setup-erlexec-sudoers.sh")
  end

  defp run_or_raise!(script, args) do
    case System.cmd(script, args,
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_io, 0} ->
        :ok

      {_io, code} ->
        Mix.raise(
          "#{script} #{Enum.join(args, " ")} exited with status #{code}"
        )
    end
  end
end
