defmodule Atlas.Deploy.IAMRoleTest do
  use ExUnit.Case, async: false

  alias Atlas.Deploy.IAMRole
  alias AWS.IAM.Sandbox, as: IAMSandbox

  @params %{
    release_env: "dev",
    prefix: "cylk",
    account_id: "123456789012",
    github_owner: "cylkdev",
    github_repository: "cylk_platform",
    state_bucket: "cylk-deploy-tfstate",
    ansible_ssm_bucket: "cylk-deploy-ansible-ssm-dev",
    deploy_releases_bucket: "cylk-deploy-releases-dev"
  }

  @role_arn "arn:aws:iam::123456789012:role/cylk-deploy-dev"

  describe "build_policy/1" do
    test "returns role_name, policy_name, and description derived from defaults" do
      {:ok, built} = IAMRole.build_policy(@params)

      assert built.role_name == "cylk-deploy-dev"
      assert built.policy_name == "deploy"

      assert built.role_description ==
               "GitHub Actions role for deploy-pipeline in dev (terraform + ansible)"
    end

    test "trust policy binds the github environment subject" do
      {:ok, %{trust_policy: trust}} = IAMRole.build_policy(@params)

      [statement] = trust["Statement"]
      assert statement["Effect"] == "Allow"
      assert statement["Action"] == "sts:AssumeRoleWithWebIdentity"

      assert statement["Principal"]["Federated"] ==
               "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"

      assert statement["Condition"]["StringEquals"][
               "token.actions.githubusercontent.com:aud"
             ] == "sts.amazonaws.com"

      assert statement["Condition"]["ForAnyValue:StringEquals"][
               "token.actions.githubusercontent.com:sub"
             ] == ["repo:cylkdev/cylk_platform:environment:deploy-dev"]
    end

    test "github_environment override is respected" do
      {:ok, %{trust_policy: trust}} =
        IAMRole.build_policy(Map.put(@params, :github_environment, "deploy-prod"))

      [statement] = trust["Statement"]

      assert statement["Condition"]["ForAnyValue:StringEquals"][
               "token.actions.githubusercontent.com:sub"
             ] == ["repo:cylkdev/cylk_platform:environment:deploy-prod"]
    end

    test "role policy contains every Sid from the bash script" do
      {:ok, %{role_policy: policy}} = IAMRole.build_policy(@params)
      sids = Enum.map(policy["Statement"], & &1["Sid"]) |> Enum.sort()

      expected =
        Enum.sort([
          "TerraformState",
          "TerraformStateObjects",
          "KmsViaS3",
          "NetworkManage",
          "ComputeManage",
          "AutoScalingManage",
          "ElbManage",
          "SqsManage",
          "EventBridgeManage",
          "EventBridgeConnectionSecretsCreate",
          "EventBridgeConnectionSecretsManage",
          "IamManage",
          "ServiceLinkedRoles",
          "AcmManage",
          "SsmDescribe",
          "SsmSession",
          "SsmSendCommand",
          "AnsibleSsmStagingBucket",
          "AnsibleSsmStagingObjects",
          "DeployStagingBucket",
          "DeployStagingObjects"
        ])

      assert sids == expected
    end

    test "bucket ARNs interpolate the supplied bucket names" do
      {:ok, %{role_policy: policy}} = IAMRole.build_policy(@params)

      sid = fn s -> Enum.find(policy["Statement"], &(&1["Sid"] == s)) end

      assert sid.("TerraformState")["Resource"] == "arn:aws:s3:::cylk-deploy-tfstate"
      assert sid.("TerraformStateObjects")["Resource"] == "arn:aws:s3:::cylk-deploy-tfstate/*"

      assert sid.("AnsibleSsmStagingObjects")["Resource"] ==
               "arn:aws:s3:::cylk-deploy-ansible-ssm-dev/*"

      assert sid.("DeployStagingObjects")["Resource"] ==
               "arn:aws:s3:::cylk-deploy-releases-dev/*"
    end

    test "account_id is interpolated into ServiceLinkedRoles and SsmSession" do
      {:ok, %{role_policy: policy}} = IAMRole.build_policy(@params)

      sid = fn s -> Enum.find(policy["Statement"], &(&1["Sid"] == s)) end

      assert Enum.all?(
               sid.("ServiceLinkedRoles")["Resource"],
               &String.contains?(&1, "arn:aws:iam::123456789012:")
             )

      assert Enum.any?(
               sid.("SsmSession")["Resource"],
               &(&1 == "arn:aws:ec2:*:123456789012:instance/*")
             )
    end

    test "missing required key returns ErrorMessage.bad_request" do
      params = Map.delete(@params, :state_bucket)

      assert {:error, %ErrorMessage{code: :bad_request, details: %{missing_keys: [:state_bucket]}}} =
               IAMRole.build_policy(params)
    end

    test "non-map params is rejected" do
      assert {:error, %ErrorMessage{code: :bad_request}} = IAMRole.build_policy("nope")
    end
  end

  describe "apply_policy/1" do
    test "creates the role when get_role returns not_found" do
      IAMSandbox.set_get_role_responses([
        {"cylk-deploy-dev",
         fn -> {:error, ErrorMessage.not_found("resource not found.", %{})} end}
      ])

      IAMSandbox.set_create_role_responses([
        {"cylk-deploy-dev",
         fn -> {:ok, %{role_name: "cylk-deploy-dev", role_id: "AROA123", arn: @role_arn}} end}
      ])

      IAMSandbox.set_put_role_policy_responses([
        {"cylk-deploy-dev", fn -> {:ok, %{}} end}
      ])

      assert {:ok, %{role_arn: @role_arn, action: :created}} = IAMRole.apply_policy(@params)
    end

    test "updates the trust policy when the role already exists" do
      IAMSandbox.set_get_role_responses([
        {"cylk-deploy-dev",
         fn -> {:ok, %{role_name: "cylk-deploy-dev", role_id: "AROA123", arn: @role_arn}} end}
      ])

      IAMSandbox.set_update_assume_role_policy_responses([
        {"cylk-deploy-dev", fn -> {:ok, %{}} end}
      ])

      IAMSandbox.set_put_role_policy_responses([
        {"cylk-deploy-dev", fn -> {:ok, %{}} end}
      ])

      assert {:ok, %{role_arn: @role_arn, action: :updated}} = IAMRole.apply_policy(@params)
    end

    test "propagates a put_role_policy failure as an ErrorMessage" do
      IAMSandbox.set_get_role_responses([
        {"cylk-deploy-dev",
         fn -> {:ok, %{role_name: "cylk-deploy-dev", role_id: "AROA123", arn: @role_arn}} end}
      ])

      IAMSandbox.set_update_assume_role_policy_responses([
        {"cylk-deploy-dev", fn -> {:ok, %{}} end}
      ])

      IAMSandbox.set_put_role_policy_responses([
        {"cylk-deploy-dev",
         fn -> {:error, ErrorMessage.not_found("denied", %{response: "AccessDenied"})} end}
      ])

      assert {:error, %ErrorMessage{code: :not_found}} = IAMRole.apply_policy(@params)
    end

    test "propagates a build_policy validation error without calling AWS" do
      assert {:error, %ErrorMessage{code: :bad_request}} =
               IAMRole.apply_policy(Map.delete(@params, :prefix))
    end
  end

  describe "verify_policy/1" do
    test "returns matches=true when get_role_policy equals build_policy output" do
      {:ok, %{role_policy: expected}} = IAMRole.build_policy(@params)

      IAMSandbox.set_get_role_responses([
        {"cylk-deploy-dev",
         fn -> {:ok, %{role_name: "cylk-deploy-dev", role_id: "AROA123", arn: @role_arn}} end}
      ])

      IAMSandbox.set_get_role_policy_responses([
        {"cylk-deploy-dev",
         fn ->
           {:ok,
            %{role_name: "cylk-deploy-dev", policy_name: "deploy", policy_document: expected}}
         end}
      ])

      assert {:ok,
              %{role_arn: @role_arn, role_exists: true, policy_document_matches: true}} =
               IAMRole.verify_policy(@params)
    end

    test "returns matches=true even when action lists are in a different order" do
      {:ok, %{role_policy: expected}} = IAMRole.build_policy(@params)
      shuffled = shuffle_actions(expected)

      IAMSandbox.set_get_role_responses([
        {"cylk-deploy-dev",
         fn -> {:ok, %{role_name: "cylk-deploy-dev", role_id: "AROA123", arn: @role_arn}} end}
      ])

      IAMSandbox.set_get_role_policy_responses([
        {"cylk-deploy-dev",
         fn ->
           {:ok,
            %{role_name: "cylk-deploy-dev", policy_name: "deploy", policy_document: shuffled}}
         end}
      ])

      assert {:ok, %{policy_document_matches: true}} = IAMRole.verify_policy(@params)
    end

    test "returns matches=false when a statement is dropped" do
      {:ok, %{role_policy: expected}} = IAMRole.build_policy(@params)

      drifted = %{
        expected
        | "Statement" =>
            Enum.reject(expected["Statement"], &(&1["Sid"] == "DeployStagingObjects"))
      }

      IAMSandbox.set_get_role_responses([
        {"cylk-deploy-dev",
         fn -> {:ok, %{role_name: "cylk-deploy-dev", role_id: "AROA123", arn: @role_arn}} end}
      ])

      IAMSandbox.set_get_role_policy_responses([
        {"cylk-deploy-dev",
         fn ->
           {:ok,
            %{role_name: "cylk-deploy-dev", policy_name: "deploy", policy_document: drifted}}
         end}
      ])

      assert {:ok, %{role_arn: @role_arn, role_exists: true, policy_document_matches: false}} =
               IAMRole.verify_policy(@params)
    end

    test "returns role_exists=false when get_role is not_found" do
      IAMSandbox.set_get_role_responses([
        {"cylk-deploy-dev",
         fn -> {:error, ErrorMessage.not_found("resource not found.", %{})} end}
      ])

      assert {:ok, %{role_arn: nil, role_exists: false, policy_document_matches: false}} =
               IAMRole.verify_policy(@params)
    end
  end

  describe "discover_account_id/0" do
    test "extracts :account from AWS.STS.get_caller_identity" do
      AWS.STS.Sandbox.set_get_caller_identity_responses([
        fn ->
          {:ok,
           %{account: "123456789012", arn: "arn:aws:iam::123:user/x", user_id: "AIDA"}}
        end
      ])

      assert {:ok, "123456789012"} = IAMRole.discover_account_id()
    end
  end

  defp shuffle_actions(%{"Statement" => statements} = doc) do
    %{
      doc
      | "Statement" =>
          Enum.map(statements, fn s ->
            case Map.get(s, "Action") do
              actions when is_list(actions) -> %{s | "Action" => Enum.reverse(actions)}
              _ -> s
            end
          end)
    }
  end
end
