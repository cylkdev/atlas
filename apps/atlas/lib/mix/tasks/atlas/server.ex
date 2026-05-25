defmodule Mix.Tasks.Atlas.Server do
  @shortdoc "Start the Atlas supervision tree with `Atlas.Endpoint` serving HTTP"

  @moduledoc """
  Boots `:atlas` with the HTTP endpoint enabled, mirroring
  `mix phx.server`.

      mix atlas.server
      iex -S mix atlas.server

  ## How it works

  By default `Atlas.Endpoint` is always supervised but does **not**
  bind a port — `Atlas.Endpoint.init/1` only adds the Bandit child to
  its supervision tree when `Atlas.Endpoint.server?/0` returns `true`.

  This task flips the **global** override key before the `:atlas` app
  starts:

      Application.put_env(:atlas, :serve_endpoints, true, persistent: true)

  When `Atlas.Endpoint.init/1` runs as part of normal application
  startup, it sees `:serve_endpoints` is `true` and includes the
  Bandit child. The `persistent: true` option ensures the value
  survives an `Application.stop(:atlas)` / `Application.start(:atlas)`
  cycle within the same node.

  When invoked under `iex -S mix atlas.server` the IEx shell keeps the
  node alive on its own. When invoked as `mix atlas.server` (no IEx),
  this task blocks via `Process.sleep(:infinity)` so the BEAM does not
  exit immediately after `start/2` returns.

  ## Declarative alternative

  Consumers that want the endpoint to start on every boot — without
  going through this task — can set the **per-endpoint** flag in their
  `config/config.exs` (or `config/runtime.exs`) directly:

      config :atlas, Atlas.Endpoint,
        scheme: :http,
        port: 4400,
        server: true

  The two paths are independent: `:atlas, :serve_endpoints` (global,
  set by this task) and `:atlas, Atlas.Endpoint, server:` (per-endpoint,
  set by the consumer) are ORed inside `Atlas.Endpoint.server?/1`.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_argv) do
    enable_server!()
    {:ok, _started} = Application.ensure_all_started(:atlas)

    unless iex_running?() do
      Process.sleep(:infinity)
    end

    :ok
  end

  @doc """
  Flips the global `:atlas, :serve_endpoints` env to `true`,
  persistently, so a subsequent `Application.ensure_all_started(:atlas)`
  brings up `Atlas.Endpoint`'s Bandit child. Exposed for testability —
  the task body calls this before starting `:atlas`.
  """
  @spec enable_server!() :: :ok
  def enable_server! do
    Application.put_env(:atlas, :serve_endpoints, true, persistent: true)
  end

  @spec iex_running?() :: boolean()
  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
