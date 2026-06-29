defmodule Atlas.Providers.AWS.ClientStub do
  @moduledoc """
  In-memory `Atlas.Providers.AWS.Client` for tests. Holds a fixed set of
  instances and a per-instance ping-status map in a named Agent. Not a
  mocking library — a real module implementing the behaviour, configured
  per test via `set/1`. Use with `async: false`.
  """

  @behaviour Atlas.Providers.AWS.Client

  use Agent

  def start_link(state) do
    initial = Map.merge(%{instances: [], ping: %{}, describe_result: nil}, state)
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  @doc "Merge configuration: `:instances`, `:ping` (id => status), `:describe_result`."
  def set(state), do: Agent.update(__MODULE__, &Map.merge(&1, state))

  @impl true
  def describe_instances(_opts) do
    Agent.get(__MODULE__, fn state ->
      state.describe_result || {:ok, %{reservations: [%{instances: state.instances}]}}
    end)
  end

  @impl true
  def describe_instance_information(opts) do
    [%{"Key" => "InstanceIds", "Values" => [id]}] = Keyword.fetch!(opts, :filters)

    case Agent.get(__MODULE__, & &1.ping)[id] do
      nil -> {:ok, %{instance_information_list: []}}
      status -> {:ok, %{instance_information_list: [%{ping_status: status}]}}
    end
  end

  @impl true
  def describe_security_groups(_opts), do: {:ok, %{security_groups: []}}
end
