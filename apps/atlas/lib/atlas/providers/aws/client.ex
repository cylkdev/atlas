defmodule Atlas.Providers.AWS.Client do
  @moduledoc """
  Behaviour for the AWS calls `Atlas.Providers.AWS.SSM` makes, so the
  provider can be driven with a stub module in tests without reaching
  real AWS. Callers pass the implementing module as the `:client`
  argument; it defaults to `Atlas.Providers.AWS.Client.Live`, which
  delegates to the `:aws` dependency.
  """

  @callback describe_instances(opts :: keyword()) :: {:ok, map()} | {:error, term()}
  @callback describe_instance_information(opts :: keyword()) :: {:ok, map()} | {:error, term()}
  @callback describe_security_groups(opts :: keyword()) :: {:ok, map()} | {:error, term()}

  defmodule Live do
    @moduledoc "Default `Atlas.Providers.AWS.Client` backed by the `:aws` dependency."

    @behaviour Atlas.Providers.AWS.Client

    @impl true
    def describe_instances(opts), do: AWS.EC2.describe_instances(opts)

    @impl true
    def describe_instance_information(opts), do: AWS.SSM.describe_instance_information(opts)

    @impl true
    def describe_security_groups(opts), do: AWS.EC2.describe_security_groups(opts)
  end
end
