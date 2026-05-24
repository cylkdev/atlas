defmodule Mix.Atlas.DeployIamRoleParams do
  @moduledoc false

  alias Atlas.Deploy.IAMRole
  alias Mix.Atlas.Options

  @required [
    :release_env,
    :prefix,
    :github_owner,
    :github_repository,
    :state_bucket,
    :ansible_ssm_bucket,
    :deploy_releases_bucket
  ]

  @optional [:github_environment, :role_name, :policy_name]

  @doc """
  Builds the `Atlas.Deploy.IAMRole` params map from parsed CLI options.

  Discovers `account_id` via `Atlas.Deploy.IAMRole.discover_account_id/0`
  when `--account-id` is not supplied. Raises via `Mix.raise/1` on any
  missing required flag or STS failure.
  """
  @spec from_opts!(keyword()) :: map()
  def from_opts!(opts) do
    base = Enum.into(@required, %{}, fn key -> {key, Options.fetch_one!(opts, key)} end)

    optional =
      @optional
      |> Enum.map(fn key -> {key, Options.fetch_one(opts, key)} end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    base
    |> Map.merge(optional)
    |> Map.put(:account_id, resolve_account_id!(opts))
  end

  defp resolve_account_id!(opts) do
    case Options.fetch_one(opts, :account_id) do
      nil -> discover_or_raise!()
      value -> value
    end
  end

  defp discover_or_raise! do
    case IAMRole.discover_account_id() do
      {:ok, account_id} ->
        account_id

      {:error, %ErrorMessage{} = e} ->
        Mix.raise(
          "could not discover AWS account id (pass --account-id to override): " <>
            ErrorMessage.to_string(e)
        )
    end
  end
end
