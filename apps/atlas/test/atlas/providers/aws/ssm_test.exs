defmodule Atlas.Providers.AWS.SSMTest do
  # async: false — ClientStub is a named Agent (shared global state).
  use ExUnit.Case, async: false

  alias Atlas.Providers.AWS.ClientStub
  alias Atlas.Providers.AWS.SSM

  @ctx %{workflow_id: "wf", step_id: "ssm-wait"}

  setup do
    start_supervised!({ClientStub, %{}})
    :ok
  end

  defp instance(id, opts \\ []) do
    %{
      instance_id: id,
      launch_time: Keyword.get(opts, :launch_time, "2020-01-01T00:00:00Z"),
      vpc_id: Keyword.get(opts, :vpc_id)
    }
  end

  defp wait(args) do
    base = %{
      action: :wait,
      release_environment: "dev",
      release_group: "cylk",
      client: ClientStub,
      max_attempts: 2,
      poll_interval_ms: 1
    }

    SSM.call(Map.merge(base, args), %{}, @ctx)
  end

  describe "call/3 :wait readiness" do
    test "returns ok when count instances are present and all Online" do
      ClientStub.set(%{
        instances: [instance("i-1"), instance("i-2")],
        ping: %{"i-1" => "Online", "i-2" => "Online"}
      })

      assert {:ok, %{instance_ids: ids}} = wait(%{count: 2, max_attempts: 1})
      assert Enum.sort(ids) == ["i-1", "i-2"]
    end

    test "counts pre-existing instances regardless of launch_time (the re-deploy case)" do
      # launch_time long in the past — the old `:since` filter would have
      # rejected these; the count-based gate must accept them.
      ClientStub.set(%{
        instances: [
          instance("i-old-1", launch_time: "2020-01-01T00:00:00Z"),
          instance("i-old-2", launch_time: "2020-01-01T00:00:00Z")
        ],
        ping: %{"i-old-1" => "Online", "i-old-2" => "Online"}
      })

      assert {:ok, %{instance_ids: ids}} = wait(%{count: 2, max_attempts: 1})
      assert Enum.sort(ids) == ["i-old-1", "i-old-2"]
    end

    test "times out when fewer than count instances exist, even if all Online" do
      ClientStub.set(%{instances: [instance("i-1")], ping: %{"i-1" => "Online"}})

      assert {:error, %{reason: :timeout}, _} = wait(%{count: 2})
    end

    test "times out when count is met but an instance is not Online" do
      ClientStub.set(%{
        instances: [instance("i-1"), instance("i-2")],
        ping: %{"i-1" => "Online", "i-2" => "ConnectionLost"}
      })

      assert {:error, %{reason: :timeout, pending: pending}, _} = wait(%{count: 2})
      assert "i-2" in pending
    end

    test "times out when no matching instances exist" do
      ClientStub.set(%{instances: []})
      assert {:error, %{reason: :timeout}, _} = wait(%{count: 2})
    end
  end

  describe "call/3 errors" do
    test "surfaces describe_instances failure" do
      ClientStub.set(%{describe_result: {:error, :boom}})

      assert {:error, %{reason: :describe_instances_failed, error: :boom}} = wait(%{count: 1})
    end

    test "missing :count is a missing_argument error" do
      assert {:error, {:missing_argument, :count}} =
               SSM.call(%{action: :wait, release_environment: "dev", client: ClientStub}, %{}, @ctx)
    end

    test "unknown action is rejected" do
      assert {:error, {:invalid_action, :nope}} = SSM.call(%{action: :nope}, %{}, @ctx)
    end
  end
end
