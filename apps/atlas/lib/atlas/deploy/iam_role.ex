defmodule Atlas.Deploy.IAMRole do
  @moduledoc """
  Builds, applies, and verifies the GitHub Actions OIDC deploy role
  used by the deploy pipeline (trust policy + large inline role policy).

  Replaces the `bin/aws-create-deploy-role.sh` bash script. The three
  public entry points are independent seams:

    * `build_policy/1` is pure — assembles the trust policy and the
      inline role policy from a params map. Use it to inspect the
      generated policy without touching AWS.
    * `apply_policy/1` creates the role if it does not exist, otherwise
      updates its trust policy, then writes the inline role policy.
    * `verify_policy/1` reads the inline role policy back and compares
      it structurally to what `build_policy/1` would produce. The role
      existence is confirmed but the trust policy document itself is
      not deep-compared — `AWS.IAM.get_role/2` in the current `:aws`
      dep does not surface `AssumeRolePolicyDocument`.

  All AWS credentials and the region are resolved from the umbrella
  `config :aws, ...` chain — no per-call overrides.

  Required `params` keys:

    * `:release_env` (`String.t()`) — e.g. `"dev"`.
    * `:prefix` (`String.t()`) — e.g. `"cylk"`.
    * `:account_id` (`String.t()`).
    * `:github_owner` (`String.t()`).
    * `:github_repository` (`String.t()`).
    * `:state_bucket` (`String.t()`).
    * `:ansible_ssm_bucket` (`String.t()`).
    * `:deploy_releases_bucket` (`String.t()`).

  Optional `params` keys (with defaults):

    * `:github_environment` (`String.t()`) — defaults to
      `"deploy-\#{release_env}"`.
    * `:role_name` (`String.t()`) — defaults to
      `"\#{prefix}-deploy-\#{release_env}"`.
    * `:policy_name` (`String.t()`) — defaults to `"deploy"`.
  """

  @required_keys [
    :release_env,
    :prefix,
    :account_id,
    :github_owner,
    :github_repository,
    :state_bucket,
    :ansible_ssm_bucket,
    :deploy_releases_bucket
  ]

  @max_session_duration 3600
  @oidc_audience "sts.amazonaws.com"
  @oidc_provider_host "token.actions.githubusercontent.com"

  @type params :: %{optional(atom()) => String.t()}

  @type built :: %{
          role_name: String.t(),
          policy_name: String.t(),
          role_description: String.t(),
          trust_policy: map(),
          role_policy: map()
        }

  # ---------------------------------------------------------------------------
  # build_policy/1
  # ---------------------------------------------------------------------------

  @doc """
  Assembles the trust policy and inline role policy documents.

  Returns the documents as Elixir maps (the `:aws` library JSON-encodes
  them before sending). Pure — no AWS calls.
  """
  @spec build_policy(params()) :: {:ok, built()} | {:error, ErrorMessage.t()}
  def build_policy(params) do
    with :ok <- validate_required(params) do
      resolved = resolve_defaults(params)

      {:ok,
       %{
         role_name: resolved.role_name,
         policy_name: resolved.policy_name,
         role_description:
           "GitHub Actions role for deploy-pipeline in #{resolved.release_env} (terraform + ansible)",
         trust_policy: trust_policy(resolved),
         role_policy: role_policy(resolved)
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # apply_policy/1
  # ---------------------------------------------------------------------------

  @doc """
  Creates or updates the deploy role, then writes the inline role policy.

  Returns the role ARN and which branch was taken (`:created` on first
  application, `:updated` on subsequent applications).
  """
  @spec apply_policy(params()) ::
          {:ok, %{role_arn: String.t(), action: :created | :updated}}
          | {:error, ErrorMessage.t()}
  def apply_policy(params) do
    with {:ok, built} <- build_policy(params),
         {:ok, action, role} <- ensure_role(built),
         :ok <- put_inline_policy(built) do
      {:ok, %{role_arn: role.arn, action: action}}
    end
  end

  # ---------------------------------------------------------------------------
  # verify_policy/1
  # ---------------------------------------------------------------------------

  @doc """
  Reads the role and its inline policy back from AWS and compares the
  inline policy structurally against `build_policy/1`'s output.

  Returns:

    * `:role_arn` — the live role ARN, when found.
    * `:role_exists` — `true` if `AWS.IAM.get_role/2` succeeded.
    * `:policy_document_matches` — `true` if the inline role policy on
      AWS matches the generated one after key/order normalisation.
  """
  @spec verify_policy(params()) ::
          {:ok,
           %{
             role_arn: String.t() | nil,
             role_exists: boolean(),
             policy_document_matches: boolean()
           }}
          | {:error, ErrorMessage.t()}
  def verify_policy(params) do
    with {:ok, built} <- build_policy(params) do
      case AWS.IAM.get_role(built.role_name) do
        {:ok, role} ->
          compare_inline_policy(built, role)

        {:error, %ErrorMessage{code: :not_found}} ->
          {:ok, %{role_arn: nil, role_exists: false, policy_document_matches: false}}

        {:error, _} = err ->
          err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # discover_account_id/0
  # ---------------------------------------------------------------------------

  @doc """
  Looks up the active AWS account id via `AWS.STS.get_caller_identity/1`.

  Used by the Mix tasks when `--account-id` is not supplied. Library
  callers can call this to populate `params.account_id` or pass their
  own value.
  """
  @spec discover_account_id() :: {:ok, String.t()} | {:error, ErrorMessage.t()}
  def discover_account_id do
    case AWS.STS.get_caller_identity([]) do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — apply
  # ---------------------------------------------------------------------------

  defp ensure_role(built) do
    case AWS.IAM.get_role(built.role_name) do
      {:ok, role} ->
        with {:ok, _} <- AWS.IAM.update_assume_role_policy(built.role_name, built.trust_policy) do
          {:ok, :updated, role}
        end

      {:error, %ErrorMessage{code: :not_found}} ->
        opts = [
          description: built.role_description,
          max_session_duration: @max_session_duration
        ]

        with {:ok, role} <- AWS.IAM.create_role(built.role_name, built.trust_policy, opts) do
          {:ok, :created, role}
        end

      {:error, _} = err ->
        err
    end
  end

  defp put_inline_policy(built) do
    case AWS.IAM.put_role_policy(built.role_name, built.policy_name, built.role_policy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — verify
  # ---------------------------------------------------------------------------

  defp compare_inline_policy(built, role) do
    case AWS.IAM.get_role_policy(built.role_name, built.policy_name) do
      {:ok, %{policy_document: actual}} ->
        {:ok,
         %{
           role_arn: role.arn,
           role_exists: true,
           policy_document_matches: normalise(actual) === normalise(built.role_policy)
         }}

      {:error, %ErrorMessage{code: :not_found}} ->
        {:ok,
         %{
           role_arn: role.arn,
           role_exists: true,
           policy_document_matches: false
         }}

      {:error, _} = err ->
        err
    end
  end

  # Recursively normalises a policy document for structural comparison:
  # stringifies keys, lowercases them, and sorts list-valued Action /
  # Resource fields so order-only differences do not register as drift.
  defp normalise(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {normalise_key(k), normalise_value(k, v)} end)
    |> Map.new()
  end

  defp normalise(value) when is_list(value), do: Enum.map(value, &normalise/1)
  defp normalise(value), do: value

  defp normalise_key(k) when is_atom(k), do: k |> Atom.to_string() |> String.downcase()
  defp normalise_key(k) when is_binary(k), do: String.downcase(k)

  defp normalise_value(k, v) when is_list(v) do
    if order_insensitive?(k) and Enum.all?(v, &is_binary/1) do
      Enum.sort(v)
    else
      Enum.map(v, &normalise/1)
    end
  end

  defp normalise_value(_k, v), do: normalise(v)

  @order_insensitive_keys ~w(action resource notaction notresource)

  defp order_insensitive?(k) do
    downcased = k |> to_string() |> String.downcase()
    downcased in @order_insensitive_keys
  end

  # ---------------------------------------------------------------------------
  # Internals — params resolution
  # ---------------------------------------------------------------------------

  defp validate_required(params) when is_map(params) do
    missing = Enum.reject(@required_keys, &Map.has_key?(params, &1))

    case missing do
      [] ->
        :ok

      keys ->
        {:error,
         ErrorMessage.bad_request(
           "missing required deploy-role params: #{Enum.map_join(keys, ", ", &inspect/1)}",
           %{missing_keys: keys}
         )}
    end
  end

  defp validate_required(_),
    do: {:error, ErrorMessage.bad_request("params must be a map", %{})}

  defp resolve_defaults(params) do
    release_env = params.release_env
    prefix = params.prefix

    %{
      release_env: release_env,
      prefix: prefix,
      account_id: params.account_id,
      github_owner: params.github_owner,
      github_repository: params.github_repository,
      github_environment:
        Map.get(params, :github_environment) || "deploy-#{release_env}",
      role_name: Map.get(params, :role_name) || "#{prefix}-deploy-#{release_env}",
      policy_name: Map.get(params, :policy_name) || "deploy",
      state_bucket: params.state_bucket,
      ansible_ssm_bucket: params.ansible_ssm_bucket,
      deploy_releases_bucket: params.deploy_releases_bucket
    }
  end

  # ---------------------------------------------------------------------------
  # Trust policy
  # ---------------------------------------------------------------------------

  defp trust_policy(r) do
    %{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Effect" => "Allow",
          "Principal" => %{
            "Federated" => "arn:aws:iam::#{r.account_id}:oidc-provider/#{@oidc_provider_host}"
          },
          "Action" => "sts:AssumeRoleWithWebIdentity",
          "Condition" => %{
            "StringEquals" => %{
              "#{@oidc_provider_host}:aud" => @oidc_audience
            },
            "ForAnyValue:StringEquals" => %{
              "#{@oidc_provider_host}:sub" => [
                "repo:#{r.github_owner}/#{r.github_repository}:environment:#{r.github_environment}"
              ]
            }
          }
        }
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # Role policy
  # ---------------------------------------------------------------------------

  defp role_policy(r) do
    statements =
      List.flatten([
        terraform_state_statements(r),
        kms_via_s3_statement(),
        network_manage_statement(),
        compute_manage_statement(),
        autoscaling_manage_statement(),
        elb_manage_statement(),
        sqs_manage_statement(),
        event_bridge_manage_statement(),
        event_bridge_connection_secrets_statements(r),
        iam_manage_statement(),
        service_linked_roles_statement(r),
        acm_manage_statement(),
        ssm_describe_statement(),
        ssm_session_statement(r),
        ssm_send_command_statement(r),
        ansible_ssm_bucket_statements(r),
        deploy_releases_bucket_statements(r)
      ])

    %{"Version" => "2012-10-17", "Statement" => statements}
  end

  defp terraform_state_statements(r) do
    [
      %{
        "Sid" => "TerraformState",
        "Effect" => "Allow",
        "Action" => ["s3:GetBucketLocation", "s3:ListBucket"],
        "Resource" => "arn:aws:s3:::#{r.state_bucket}"
      },
      %{
        "Sid" => "TerraformStateObjects",
        "Effect" => "Allow",
        "Action" => ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        "Resource" => "arn:aws:s3:::#{r.state_bucket}/*"
      }
    ]
  end

  defp kms_via_s3_statement do
    %{
      "Sid" => "KmsViaS3",
      "Effect" => "Allow",
      "Action" => [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey"
      ],
      "Resource" => "*",
      "Condition" => %{
        "StringEquals" => %{"kms:ViaService" => "s3.us-east-1.amazonaws.com"}
      }
    }
  end

  defp network_manage_statement do
    %{
      "Sid" => "NetworkManage",
      "Effect" => "Allow",
      "Action" => [
        "ec2:AllocateAddress",
        "ec2:AssociateRouteTable",
        "ec2:AttachInternetGateway",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateInternetGateway",
        "ec2:CreateNatGateway",
        "ec2:CreateRoute",
        "ec2:CreateRouteTable",
        "ec2:CreateSecurityGroup",
        "ec2:CreateSubnet",
        "ec2:CreateTags",
        "ec2:CreateVpc",
        "ec2:DeleteInternetGateway",
        "ec2:DeleteNatGateway",
        "ec2:DeleteRoute",
        "ec2:DeleteRouteTable",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteSubnet",
        "ec2:DeleteTags",
        "ec2:DeleteVpc",
        "ec2:DescribeAccountAttributes",
        "ec2:DescribeAddresses",
        "ec2:DescribeAddressesAttribute",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeNatGateways",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroupRules",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeTags",
        "ec2:DescribeVpcAttribute",
        "ec2:DescribeVpcs",
        "ec2:DetachInternetGateway",
        "ec2:DisassociateRouteTable",
        "ec2:ModifySecurityGroupRules",
        "ec2:ModifySubnetAttribute",
        "ec2:ModifyVpcAttribute",
        "ec2:ReleaseAddress",
        "ec2:ReplaceRoute",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateVpcEndpoint",
        "ec2:DeleteVpcEndpoints",
        "ec2:ModifyVpcEndpoint",
        "ec2:DescribePrefixLists"
      ],
      "Resource" => "*"
    }
  end

  defp compute_manage_statement do
    %{
      "Sid" => "ComputeManage",
      "Effect" => "Allow",
      "Action" => [
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceAttribute",
        "ec2:DescribeInstanceCreditSpecifications",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeKeyPairs",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumeAttribute",
        "ec2:GetEbsDefaultKmsKeyId",
        "ec2:GetEbsEncryptionByDefault",
        "ec2:RunInstances",
        "ec2:StopInstances",
        "ec2:TerminateInstances",
        "ec2:ModifyInstanceAttribute",
        "ec2:ModifyInstanceCreditSpecification",
        "ec2:CreateLaunchTemplate",
        "ec2:CreateLaunchTemplateVersion",
        "ec2:DeleteLaunchTemplate",
        "ec2:DeleteLaunchTemplateVersions",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetLaunchTemplateData",
        "ec2:ModifyLaunchTemplate",
        "ec2:DescribeVpcEndpoints",
        "ec2:GetConsoleOutput"
      ],
      "Resource" => "*"
    }
  end

  defp autoscaling_manage_statement do
    %{
      "Sid" => "AutoScalingManage",
      "Effect" => "Allow",
      "Action" => [
        "autoscaling:CompleteLifecycleAction",
        "autoscaling:CreateAutoScalingGroup",
        "autoscaling:CreateOrUpdateTags",
        "autoscaling:DeleteAutoScalingGroup",
        "autoscaling:DeleteLifecycleHook",
        "autoscaling:DeleteTags",
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLifecycleHooks",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "autoscaling:DisableMetricsCollection",
        "autoscaling:EnableMetricsCollection",
        "autoscaling:PutLifecycleHook",
        "autoscaling:RecordLifecycleActionHeartbeat",
        "autoscaling:ResumeProcesses",
        "autoscaling:SetInstanceProtection",
        "autoscaling:SuspendProcesses",
        "autoscaling:UpdateAutoScalingGroup"
      ],
      "Resource" => "*"
    }
  end

  defp elb_manage_statement do
    %{
      "Sid" => "ElbManage",
      "Effect" => "Allow",
      "Action" => [
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateRule",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:DeleteRule",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:DescribeListenerAttributes",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeRules",
        "elasticloadbalancing:DescribeTags",
        "elasticloadbalancing:DescribeTargetGroupAttributes",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:ModifyListener",
        "elasticloadbalancing:ModifyLoadBalancerAttributes",
        "elasticloadbalancing:ModifyRule",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:RemoveTags",
        "elasticloadbalancing:SetRulePriorities",
        "elasticloadbalancing:SetSecurityGroups",
        "elasticloadbalancing:SetSubnets"
      ],
      "Resource" => "*"
    }
  end

  defp sqs_manage_statement do
    %{
      "Sid" => "SqsManage",
      "Effect" => "Allow",
      "Action" => [
        "sqs:AddPermission",
        "sqs:CreateQueue",
        "sqs:DeleteQueue",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ListQueueTags",
        "sqs:RemovePermission",
        "sqs:SetQueueAttributes",
        "sqs:TagQueue",
        "sqs:UntagQueue"
      ],
      "Resource" => "*"
    }
  end

  defp event_bridge_manage_statement do
    %{
      "Sid" => "EventBridgeManage",
      "Effect" => "Allow",
      "Action" => [
        "events:CreateApiDestination",
        "events:CreateConnection",
        "events:DeleteApiDestination",
        "events:DeleteConnection",
        "events:DeleteRule",
        "events:DescribeApiDestination",
        "events:DescribeConnection",
        "events:DescribeRule",
        "events:DisableRule",
        "events:EnableRule",
        "events:ListApiDestinations",
        "events:ListConnections",
        "events:ListRules",
        "events:ListTagsForResource",
        "events:ListTargetsByRule",
        "events:PutRule",
        "events:PutTargets",
        "events:RemoveTargets",
        "events:TagResource",
        "events:UntagResource",
        "events:UpdateApiDestination",
        "events:UpdateConnection"
      ],
      "Resource" => "*"
    }
  end

  defp event_bridge_connection_secrets_statements(r) do
    [
      %{
        "Sid" => "EventBridgeConnectionSecretsCreate",
        "Effect" => "Allow",
        "Action" => "secretsmanager:CreateSecret",
        "Resource" => "*",
        "Condition" => %{
          "StringLike" => %{"secretsmanager:Name" => "events!connection/*"}
        }
      },
      %{
        "Sid" => "EventBridgeConnectionSecretsManage",
        "Effect" => "Allow",
        "Action" => [
          "secretsmanager:DeleteSecret",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:TagResource",
          "secretsmanager:UntagResource",
          "secretsmanager:UpdateSecret"
        ],
        "Resource" => "arn:aws:secretsmanager:*:#{r.account_id}:secret:events!connection/*"
      }
    ]
  end

  defp iam_manage_statement do
    %{
      "Sid" => "IamManage",
      "Effect" => "Allow",
      "Action" => [
        "iam:AddRoleToInstanceProfile",
        "iam:AttachRolePolicy",
        "iam:CreateInstanceProfile",
        "iam:CreateRole",
        "iam:DeleteInstanceProfile",
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:DetachRolePolicy",
        "iam:GetInstanceProfile",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:ListRolePolicies",
        "iam:PassRole",
        "iam:PutRolePolicy",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:TagRole",
        "iam:UntagInstanceProfile",
        "iam:UntagRole",
        "iam:UpdateAssumeRolePolicy"
      ],
      "Resource" => "*"
    }
  end

  defp service_linked_roles_statement(r) do
    %{
      "Sid" => "ServiceLinkedRoles",
      "Effect" => "Allow",
      "Action" => "iam:CreateServiceLinkedRole",
      "Resource" => [
        "arn:aws:iam::#{r.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
        "arn:aws:iam::#{r.account_id}:role/aws-service-role/apidestinations.events.amazonaws.com/AWSServiceRoleForAmazonEventBridgeApiDestinations",
        "arn:aws:iam::#{r.account_id}:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing"
      ],
      "Condition" => %{
        "StringLike" => %{
          "iam:AWSServiceName" => [
            "autoscaling.amazonaws.com",
            "apidestinations.events.amazonaws.com",
            "elasticloadbalancing.amazonaws.com"
          ]
        }
      }
    }
  end

  defp acm_manage_statement do
    %{
      "Sid" => "AcmManage",
      "Effect" => "Allow",
      "Action" => [
        "acm:AddTagsToCertificate",
        "acm:DeleteCertificate",
        "acm:DescribeCertificate",
        "acm:ImportCertificate",
        "acm:ListCertificates",
        "acm:ListTagsForCertificate",
        "acm:RemoveTagsFromCertificate"
      ],
      "Resource" => "*"
    }
  end

  defp ssm_describe_statement do
    %{
      "Sid" => "SsmDescribe",
      "Effect" => "Allow",
      "Action" => [
        "ssm:DescribeInstanceInformation",
        "ssm:DescribeSessions",
        "ssm:ListCommands",
        "ssm:ListCommandInvocations"
      ],
      "Resource" => "*"
    }
  end

  defp ssm_session_statement(r) do
    %{
      "Sid" => "SsmSession",
      "Effect" => "Allow",
      "Action" => [
        "ssm:StartSession",
        "ssm:ResumeSession",
        "ssm:TerminateSession"
      ],
      "Resource" => [
        "arn:aws:ec2:*:#{r.account_id}:instance/*",
        "arn:aws:ssm:*:#{r.account_id}:session/*",
        "arn:aws:ssm:*::document/AWS-StartSSHSession",
        "arn:aws:ssm:*::document/AWS-StartInteractiveCommand",
        "arn:aws:ssm:*::document/AWS-StartNonInteractiveCommand",
        "arn:aws:ssm:*:#{r.account_id}:document/SSM-SessionManagerRunShell"
      ]
    }
  end

  defp ssm_send_command_statement(r) do
    %{
      "Sid" => "SsmSendCommand",
      "Effect" => "Allow",
      "Action" => ["ssm:SendCommand", "ssm:GetCommandInvocation"],
      "Resource" => [
        "arn:aws:ec2:*:#{r.account_id}:instance/*",
        "arn:aws:ssm:*::document/AWS-RunShellScript",
        "arn:aws:ssm:*:#{r.account_id}:document/*"
      ]
    }
  end

  defp ansible_ssm_bucket_statements(r) do
    [
      %{
        "Sid" => "AnsibleSsmStagingBucket",
        "Effect" => "Allow",
        "Action" => ["s3:GetBucketLocation", "s3:ListBucket"],
        "Resource" => "arn:aws:s3:::#{r.ansible_ssm_bucket}"
      },
      %{
        "Sid" => "AnsibleSsmStagingObjects",
        "Effect" => "Allow",
        "Action" => ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        "Resource" => "arn:aws:s3:::#{r.ansible_ssm_bucket}/*"
      }
    ]
  end

  defp deploy_releases_bucket_statements(r) do
    [
      %{
        "Sid" => "DeployStagingBucket",
        "Effect" => "Allow",
        "Action" => ["s3:GetBucketLocation", "s3:ListBucket"],
        "Resource" => "arn:aws:s3:::#{r.deploy_releases_bucket}"
      },
      %{
        "Sid" => "DeployStagingObjects",
        "Effect" => "Allow",
        "Action" => ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        "Resource" => "arn:aws:s3:::#{r.deploy_releases_bucket}/*"
      }
    ]
  end
end
