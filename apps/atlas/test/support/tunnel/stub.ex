defmodule Atlas.Tunnel.Stub do
  @moduledoc """
  Test-only `Atlas.Tunnel` backend.

  Lives under `test/support/` so it compiles only in the `:test` env
  (see `mix.exs`'s `elixirc_paths/1`). Production code must never
  reference this module.

  Records its lifecycle calls in an ETS table so unit tests can
  assert on the exact order of `start_link`, `url`, and `stop`
  invocations made by the deploy task. The recorded events live in
  `:atlas_tunnel_stub_events`, an ETS table seeded by the GenServer's
  `init/1`.
  """

  use GenServer

  @behaviour Atlas.Tunnel

  @table :atlas_tunnel_stub_events

  @default_url "https://stub.trycloudflare.com"

  # --------------------------------------------------------------------
  # Atlas.Tunnel callbacks

  @impl Atlas.Tunnel
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl Atlas.Tunnel
  def url(server), do: GenServer.call(server, :url)

  @impl Atlas.Tunnel
  def stop(server) do
    if Process.alive?(server) do
      GenServer.stop(server, :normal, 1_000)
    else
      :ok
    end
  end

  # --------------------------------------------------------------------
  # Test helpers

  @doc """
  Resets the recorded-events table. Call from each test's `setup`.
  """
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Returns the recorded events in the order they were emitted.
  """
  def events do
    ensure_table()

    @table
    |> :ets.tab2list()
    # Drop the internal `:__seq__` counter row and any non-numeric-keyed
    # metadata (e.g. the `:__url__` override) — only positive-integer-
    # keyed rows are actual recorded events.
    |> Enum.filter(fn
      {seq, _} when is_integer(seq) and seq > 0 -> true
      _ -> false
    end)
    |> Enum.sort_by(fn {seq, _event} -> seq end)
    |> Enum.map(fn {_seq, event} -> event end)
  end

  @doc """
  Sets the URL the stub will return from `url/1`. Defaults to
  `"https://stub.trycloudflare.com"`.
  """
  def set_url(url) when is_binary(url) do
    ensure_table()
    :ets.insert(@table, {:__url__, url})
    :ok
  end

  # --------------------------------------------------------------------
  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    record({:start_link, opts})
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:url, _from, state) do
    url =
      case :ets.lookup(@table, :__url__) do
        [{:__url__, value}] -> value
        [] -> @default_url
      end

    record({:url, url})
    {:reply, {:ok, url}, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    record(:stop)
    :ok
  end

  # --------------------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:public, :named_table, :ordered_set])

      _ref ->
        @table
    end
  end

  defp record(event) do
    ensure_table()
    seq = :ets.update_counter(@table, :__seq__, 1, {:__seq__, 0})
    :ets.insert(@table, {seq, event})
  end
end
