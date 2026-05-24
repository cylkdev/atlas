defmodule Mix.Tasks.Atlas.Deploy.IamRole.Apply do
  @shortdoc "Create or update the GitHub Actions OIDC deploy role"

  @moduledoc """
  Creates the deploy role if it does not exist, updates its trust policy
  if it does, then writes the inline role policy. Runs `verify_policy/1`
  on the way out and exits non-zero if the read-back does not match.

      mix atlas.deploy.iam_role.apply \\
        --release-env dev \\
        --prefix cylk \\
        --github-owner cylkdev \\
        --github-repository cylk_platform \\
        --state-bucket cylk-deploy-tfstate \\
        --ansible-ssm-bucket cylk-deploy-ansible-ssm-dev \\
        --deploy-releases-bucket cylk-deploy-releases-dev

  Optional flags:

    * `--account-id` — defaults to the result of
      `AWS.STS.get_caller_identity/1`.
    * `--github-environment` — defaults to `"deploy-<release-env>"`.
    * `--role-name` — defaults to `"<prefix>-deploy-<release-env>"`.
    * `--policy-name` — defaults to `"deploy"`.
  """

  use Mix.Task

  alias Atlas.Deploy.IAMRole
  alias Mix.Atlas.Options

  @requirements ["app.start"]

  @switches [
    release_env: :keep,
    prefix: :keep,
    account_id: :keep,
    github_owner: :keep,
    github_repository: :keep,
    github_environment: :keep,
    state_bucket: :keep,
    ansible_ssm_bucket: :keep,
    deploy_releases_bucket: :keep,
    role_name: :keep,
    policy_name: :keep
  ]

  @impl Mix.Task
  def run(argv) do
    params = argv |> Options.parse!(@switches) |> Mix.Atlas.DeployIamRoleParams.from_opts!()

    case IAMRole.apply_policy(params) do
      {:ok, %{role_arn: arn, action: action}} ->
        Mix.shell().info("Role #{action}.")
        Mix.shell().info("Role ARN: #{arn}")
        Mix.shell().info("")
        Mix.shell().info("Set the following GitHub environment variable:")
        Mix.shell().info("  DEPLOY_ROLE_ARN = #{arn}")

        verify_or_raise!(params)

      {:error, %ErrorMessage{} = e} ->
        e |> ErrorMessage.to_string() |> Mix.raise()
    end
  end

  defp verify_or_raise!(params) do
    case IAMRole.verify_policy(params) do
      {:ok, %{role_exists: true, policy_document_matches: true}} ->
        Mix.shell().info("Verified: role exists and inline policy matches.")

      {:ok, %{role_exists: exists, policy_document_matches: matches}} ->
        Mix.raise(
          "verify failed: role_exists=#{exists} policy_document_matches=#{matches}"
        )

      {:error, %ErrorMessage{} = e} ->
        Mix.raise("verify failed: #{ErrorMessage.to_string(e)}")
    end
  end
end
