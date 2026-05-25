defmodule Atlas.Tunnel.Noop do
  @moduledoc """
  No-op `Atlas.Tunnel` backend.

  Selected by `Atlas.Tunnel.backend/0` when `config :atlas, :tunnel,
  :none`. Useful for:

    * Running `mix atlas.workflows.deploy` in a context where the
      deploy does not actually need EventBridge reachability (e.g. a
      dry-run, a synthetic test, a local smoke test).
    * Unit tests that want the tunnel-bracket code path exercised
      without spawning a real GenServer.

  `start_link/1` returns `{:ok, :noop}` — a sentinel atom — instead
  of a real pid. `url/1` returns a `{:error, :no_tunnel}` shape so a
  caller that genuinely needs the URL fails fast with a clear reason.
  `stop/1` is `:ok`.
  """

  @behaviour Atlas.Tunnel

  @impl true
  def start_link(_opts \\ []), do: {:ok, :noop}

  @impl true
  def url(:noop), do: {:error, :no_tunnel}
  def url(_other), do: {:error, :no_tunnel}

  @impl true
  def stop(_server), do: :ok
end
