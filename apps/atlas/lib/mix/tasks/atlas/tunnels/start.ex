defmodule Mix.Tasks.Atlas.Tunnels.Start do
  @shortdoc "Start the configured Atlas Cloudflare tunnel and block until killed"

  @moduledoc """
  Brings up the Cloudflare tunnel that fronts Atlas's HTTP endpoint —
  required by `Atlas.EventBridgePlug` so AWS EventBridge can POST
  auto-scaling lifecycle callbacks into the running node during a
  deploy.

  The actual tunnel implementation is selected by the `Atlas.Tunnel`
  abstraction (see `Atlas.Tunnel.backend/0`); this task is a thin
  foreground wrapper that:

    1. Starts the configured backend via `Atlas.Tunnel.start_link/1`.
    2. Retrieves and logs the public URL via `Atlas.Tunnel.url/1`.
    3. Blocks (`Process.sleep(:infinity)`) so the tunnel stays up for
       the lifetime of the task.
    4. Stops the backend cleanly on normal exit via `System.at_exit/1`.

  This task and `mix atlas.workflows.deploy` are intentionally
  **separate**: the deploy task does NOT start or stop a tunnel.
  Run this task in one process (a separate terminal, a systemd unit,
  a CI background step) and the deploy task in another. The operator
  is responsible for coordination.

  ## Usage

      mix atlas.tunnels.start
      mix atlas.tunnels.start --backend quick
      mix atlas.tunnels.start --backend named
      mix atlas.tunnels.start --backend none

  ## Switches

    * `--backend` — Override `Application.get_env(:atlas, :tunnel)` for
      this invocation only. Accepts `named` (the default), `quick`,
      `none`, or any module name like `My.Custom.Backend`. Useful for
      ad-hoc switching without editing config files. The override is
      written into the application env via `Application.put_env/3`
      and persists for the rest of the BEAM node's lifetime — fine
      for a single-purpose mix invocation, do not import this in a
      long-running supervised process.

  ## Configuration

  Each backend reads its own configuration from the application env;
  see the backend module docs:

    * `Atlas.Tunnel.Named` — `config :atlas, Atlas.Tunnel.Named, ...`
      with required `:token` and `:hostname`.
    * `Atlas.Tunnel.Quick` — `config :atlas, Atlas.Tunnel.Quick, ...`
      with optional `:local_url`, `:executable`, `:url_timeout_ms`.

  ## Exit status

  Exits 0 when the operator sends SIGINT / SIGTERM (cloudflared
  stops cleanly). Exits non-zero via `Mix.raise/1` if the backend
  fails to start or fails to report a URL within its timeout.
  """

  use Mix.Task

  alias Atlas.Tunnel

  @logger_prefix "Mix.Tasks.Atlas.Tunnels.Start"

  @switches [backend: :string]

  @impl Mix.Task
  @spec run([String.t()]) :: no_return() | :ok
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise(
        "unrecognized flag(s): " <>
          Enum.map_join(invalid, ", ", fn {flag, _} -> flag end) <>
          " (run `mix help atlas.tunnels.start` for usage)"
      )
    end

    {:ok, _started} = Application.ensure_all_started(:atlas)

    maybe_override_backend(opts[:backend])

    backend = Tunnel.backend()
    Atlas.Log.info(@logger_prefix, "starting backend #{inspect(backend)}")

    case Tunnel.start_link([]) do
      {:ok, pid} ->
        register_at_exit_cleanup(pid)
        block_until_killed(pid)

      {:error, reason} ->
        Mix.raise(
          "could not start tunnel: #{inspect(reason)} " <>
            "(backend #{inspect(backend)})"
        )
    end
  end

  # --------------------------------------------------------------------
  # Helpers exposed for testability — exercised by
  # `Mix.Tasks.Atlas.Tunnels.StartTest` without booting a real backend.

  @doc """
  Translates the `--backend` CLI string into the value
  `Application.get_env(:atlas, :tunnel)` expects.

  Accepts `"named"`, `"quick"`, `"none"`, or any string that looks
  like a module name (`"Foo.Bar"` → `Foo.Bar`). Raises a `Mix.Error`
  for any value that does not match this grammar — a typo in
  `--backend` should fail loudly at task start rather than silently
  fall back to the configured default.
  """
  @spec parse_backend_override!(String.t()) :: atom() | module()
  def parse_backend_override!("named"), do: :named
  def parse_backend_override!("quick"), do: :quick
  def parse_backend_override!("none"), do: :none

  def parse_backend_override!(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Z][A-Za-z0-9._]*$/) do
      String.to_atom("Elixir." <> value)
    else
      Mix.raise(
        ~s(invalid --backend value: #{inspect(value)}. Expected ) <>
          ~s("named", "quick", "none", or a module name like "My.Backend".)
      )
    end
  end

  defp maybe_override_backend(nil), do: :ok

  defp maybe_override_backend(value) when is_binary(value) do
    Application.put_env(:atlas, :tunnel, parse_backend_override!(value))
  end

  defp block_until_killed(pid) do
    case Tunnel.url(pid) do
      {:ok, url} ->
        Atlas.Log.info(@logger_prefix, "tunnel up at #{url}")
        Atlas.Log.info(@logger_prefix, "Ctrl-C to stop")
        Process.sleep(:infinity)

      {:error, :no_tunnel} ->
        # :none backend selected — nothing to keep alive, exit cleanly.
        Atlas.Log.info(
          @logger_prefix,
          "no tunnel configured (:atlas, :tunnel is :none) — exiting"
        )

        Tunnel.stop(pid)
        :ok

      {:error, reason} ->
        Tunnel.stop(pid)

        Mix.raise(
          "tunnel failed to report URL: #{inspect(reason)} " <>
            "(backend #{inspect(Tunnel.backend())})"
        )
    end
  end

  defp register_at_exit_cleanup(pid) do
    # Best-effort: register a hook so the backend gets a chance to
    # deprovision Cloudflare-side state on normal exit. SIGINT
    # bypasses System.at_exit; in that case the OTP shutdown sequence
    # still terminates the supervised processes that hold the tunnel.
    System.at_exit(fn _status ->
      try do
        Tunnel.stop(pid)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)
  end
end
