defmodule Mix.Tasks.Atlas.Deploy.IamRole.Verify do
  @shortdoc "Verify the GitHub Actions OIDC deploy role matches the expected policy"

  @moduledoc """
  Reads the deploy role's inline policy from AWS and compares it
  against `Atlas.Deploy.IAMRole.build_policy/1`'s output. Exits
  non-zero if the role is missing or the inline policy has drifted.

      mix atlas.deploy.iam_role.verify \\
        --release-env dev \\
        --prefix cylk \\
        --github-owner cylkdev \\
        --github-repository cylk_platform \\
        --state-bucket cylk-deploy-tfstate \\
        --ansible-ssm-bucket cylk-deploy-ansible-ssm-dev \\
        --deploy-releases-bucket cylk-deploy-releases-dev

  Accepts the same flags as `mix atlas.deploy.iam_role.apply`.
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

    case IAMRole.verify_policy(params) do
      {:ok, %{role_exists: true, policy_document_matches: true, role_arn: arn}} ->
        Mix.shell().info("OK: role exists and inline policy matches.")
        Mix.shell().info("Role ARN: #{arn}")

      {:ok, %{role_exists: false}} ->
        Mix.raise("verify failed: role does not exist")

      {:ok, %{policy_document_matches: false, role_arn: arn}} ->
        Mix.raise("verify failed: inline policy on #{arn} has drifted")

      {:error, %ErrorMessage{} = e} ->
        e |> ErrorMessage.to_string() |> Mix.raise()
    end
  end
end
