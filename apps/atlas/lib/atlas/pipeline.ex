defmodule Atlas.Pipeline do
  @moduledoc """
  Workflow definitions for deployment automation.

  `for_deployment/1` builds a deployment workflow:

      mix.atlas.releases.publish
        └── terraform.init
              └── terraform.plan
                    ├── terraform.apply
                    ├── aws.ssm.wait              ─┐
                    └── aws.auto_scaling.listen   ─┴── ansible.deploy

    1. `mix atlas.releases.publish` against the umbrella root with
       `MIX_ENV=prod`. Builds (if needed) and publishes every release
       configured under `:releases` in the umbrella's `mix.exs` to S3
       via `Atlas.Crates.publish_content`.
    2. `terraform init` against `deploys/terraform`.
    3. `terraform plan` against `deploys/terraform`, writing the binary
       plan artifact via `-out=`.
    4. `terraform apply <plan-file>` against that artifact. Runs
       concurrently with steps 5 and 6 (all three depend only on
       `terraform.plan`).
    5. `Atlas.Providers.AWS.SSM` with `action: :wait` polls
       `AWS.EC2.describe_instances` for tagged running instances whose
       `launch_time` is later than the workflow's start moment, then
       checks `AWS.SSM.describe_instance_information` for each instance's
       `ping_status`. Returns once every matching instance reports
       `"Online"`.
    6. `Atlas.Providers.AWS.AutoScaling` with `action: :listen`
       subscribes to `Atlas.AutoScaling.PubSub` and waits for
       `RELEASE_INSTANCE_COUNT` `EC2 Instance-launch Lifecycle Action`
       events from the ASG provisioned by step 4 (matched by
       `name_prefix`).
    7. `ansible-playbook deploy.yaml -i aws_ec2.yaml --extra-vars ...`
       against `deploys/ansible`. The playbook resolves the latest
       published release for `release_group` via the
       `GET /crates/:release_group/latest` HTTP endpoint and downloads
       the tarball from S3.

  The terraform provider invokes `plan`/`apply` with `-json`, so the
  stdout stream is ndjson — consumed live and dispatched as
  `%Atlas.Workflows.Event{}` values via `Atlas.Workflows.PubSub`.
  `terraform init` runs without `-json` (the flag is not supported on
  init in older terraform versions); its output is ignored.

  The ansible provider runs with `ANSIBLE_STDOUT_CALLBACK=json` and
  emits one `ansible_task` event per task per host.
  """

  alias Atlas.Workflow
  alias Atlas.Workflow.Step

  @terraform_directory "deploys/terraform"
  @ansible_directory "deploys/ansible"
  @plan_artifact "tfplan"
  @ansible_playbook "deploy.yaml"
  @ansible_inventory "aws_ec2.yaml"

  @doc """
  Build the deployment plan workflow.

  ## Setup

  Before calling `for_deployment/1` and running the returned workflow,
  the host must satisfy every dependency below. Anything missing fails
  the corresponding step at runtime.

  ### 1. Binaries on PATH

    * `mix` — invoked by the `mix.atlas.releases.publish` step via
      `Atlas.Providers.Exec` to run `mix atlas.releases.publish`
      from the umbrella root.
    * `terraform` — invoked by the `terraform.init`, `terraform.plan`,
      and `terraform.apply` steps via `Atlas.Providers.Terraform`.
    * `ansible-playbook` — invoked by the `ansible_deploy` step via
      `Atlas.Providers.Ansible` with
      `ANSIBLE_STDOUT_CALLBACK=json`.

  ### 2. Working directories and artifacts

    * `deploys/terraform/` with the `.tf` files.
    * `deploys/terraform/vars/<RELEASE_ENVIRONMENT>.tfvars` resolvable
      from the working directory `Atlas.Pipeline` runs from.
    * `deploys/ansible/deploy.yaml` (playbook) and
      `deploys/ansible/aws_ec2.yaml` (dynamic inventory).
    * `tfplan` is written by `terraform.plan` (the `:out` argument) and
      read by `terraform.apply` (the `:plan` argument). Both steps run
      in the same `cwd`, so the relative path resolves consistently.
    * `_build/prod/rel/<name>/` for each release in
      `Mix.Project.config()[:releases]` — produced and uploaded to S3
      by `mix.atlas.releases.publish`.

  ### 3. Environment variables (read at workflow build time via `System.fetch_env!/1`)

  Missing any of these raises before the workflow is queued.

  Identity (consumed by every step):

    * `RELEASE_GROUP` — the application identifier.
    * `RELEASE_ENVIRONMENT` — the deployment environment (selects the
      `<RELEASE_ENVIRONMENT>.tfvars` file).
    * `RELEASE_INSTANCE_COUNT` — number of ASG launch events to wait
      for in the listener step.

  Terraform-only (consumed by `terraform.plan`):

    * `CLOUDFLARE_ACCOUNT_ID`
    * `CLOUDFLARE_API_TOKEN`
    * `CLOUDFLARE_ZONE_ID`
    * `DB_PASSWORD`
    * `ATLAS_EVENTBRIDGE_API_KEY_NAME`
    * `ATLAS_EVENTBRIDGE_API_KEY_VALUE`

  Ansible extra-vars (consumed by `ansible.deploy` only):

    * `AWS_REGION` — `aws_region`.
    * `DEPLOY_STRATEGY` — `deploy_strategy`.

  The ansible step also receives the release identity vars derived from
  the umbrella's single `:releases` entry and its prebuilt tarball at
  `_build/<env>/<name>-<version>.tar.gz` (which must exist before the
  workflow is built): `target_app`, `target_release_version`,
  `target_release_sha256` (matches the `content_id` the publish step
  derives from the same bytes), and `target_release_tarball`.

  Optional:

    * `ATLAS_ENDPOINT_PORT` (defaults to `4000`).

  ### 4. AWS credentials

  Resolved via the chain configured in `config/config.exs`. Terraform
  reads its own AWS credentials from the same ambient environment.

  ### 5. Postgres

  A Postgres database reachable from this host. The application creates
  its own tables on first boot.

  ### 6. EventBridge → endpoint reachability

  `terraform.apply` provisions the EventBridge rule, connection, and
  API destination. The webhook URL must be publicly reachable from
  EventBridge and route to this host's HTTP endpoint.
  """
  @spec for_deployment(workflow_id :: nil | String.t()) :: Workflow.t()
  def for_deployment(workflow_id) do
    release_group = System.fetch_env!("RELEASE_GROUP")
    release_environment = System.fetch_env!("RELEASE_ENVIRONMENT")
    instance_count = String.to_integer(System.fetch_env!("RELEASE_INSTANCE_COUNT"))
    started_at = DateTime.utc_now()
    release = deploy_release!()

    var_file =
      Path.expand("deploys/terraform/vars/#{release_environment}.tfvars", File.cwd!())

    terraform_cwd = Path.expand(@terraform_directory, File.cwd!())
    ansible_cwd = Path.expand(@ansible_directory, File.cwd!())

    %Workflow{
      id: workflow_id,
      steps: [
        %Step{
          id: "mix-releases-publish",
          provider: Atlas.Providers.Exec,
          arguments: %{
            executable: "mix",
            arguments: ["atlas.releases.publish"],
            working_directory: File.cwd!(),
            env: %{"MIX_ENV" => "prod"}
          }
        },
        %Step{
          id: "terraform-init",
          provider: Atlas.Providers.Terraform,
          depends_on: ["mix-releases-publish"],
          arguments: %{
            action: :init,
            working_directory: terraform_cwd
          }
        },
        %Step{
          id: "terraform-plan",
          provider: Atlas.Providers.Terraform,
          depends_on: ["terraform-init"],
          arguments: %{
            action: :plan,
            working_directory: terraform_cwd,
            var_file: var_file,
            out: @plan_artifact,
            env: %{
              "TF_LOG" => "DEBUG",
              "TF_VAR_release_group" => release_group,
              "TF_VAR_release_environment" => release_environment,
              "TF_VAR_cloudflare_account_id" => System.fetch_env!("CLOUDFLARE_ACCOUNT_ID"),
              "TF_VAR_cloudflare_api_token" => System.fetch_env!("CLOUDFLARE_API_TOKEN"),
              "TF_VAR_cloudflare_zone_id" => System.fetch_env!("CLOUDFLARE_ZONE_ID"),
              "TF_VAR_db_password" => System.fetch_env!("DB_PASSWORD"),
              "TF_VAR_event_webhook_api_key_name" =>
                System.fetch_env!("ATLAS_EVENTBRIDGE_API_KEY_NAME"),
              "TF_VAR_event_webhook_api_key_value" =>
                System.fetch_env!("ATLAS_EVENTBRIDGE_API_KEY_VALUE")
            }
          }
        },
        %Step{
          id: "terraform-apply",
          provider: Atlas.Providers.Terraform,
          depends_on: ["terraform-plan"],
          arguments: %{
            action: :apply,
            working_directory: terraform_cwd,
            plan: @plan_artifact,
            env: %{"TF_LOG" => "DEBUG"}
          }
        },
        %Step{
          id: "aws-ssm-wait",
          provider: Atlas.Providers.AWS.SSM,
          depends_on: ["terraform-plan"],
          arguments: %{
            action: :wait,
            release_environment: release_environment,
            release_group: release_group,
            since: started_at,
            max_attempts: 60,
            poll_interval_ms: 10_000
          }
        },
        %Step{
          id: "aws-auto-scaling-listen",
          provider: Atlas.Providers.AWS.AutoScaling,
          depends_on: ["terraform-plan"],
          arguments: %{
            action: :listen,
            name_prefix: "#{release_group}-#{release_environment}-",
            count: instance_count,
            handler: {Atlas.Providers.AWS.AutoScaling.OnAutoScalingGroupLaunch, :handle},
            timeout_ms: 600_000
          }
        },
        %Step{
          id: "ansible-deploy",
          provider: Atlas.Providers.Ansible,
          depends_on: ["aws-auto-scaling-listen", "aws-ssm-wait"],
          arguments: %{
            playbook: @ansible_playbook,
            inventory: @ansible_inventory,
            working_directory: ansible_cwd,
            extra_vars: %{
              "aws_region" => System.fetch_env!("AWS_REGION"),
              "release_group" => release_group,
              "release_environment" => release_environment,
              "deploy_strategy" => System.fetch_env!("DEPLOY_STRATEGY"),
              "target_app" => release.app,
              "target_release_version" => release.version,
              "target_release_sha256" => release.sha256,
              "target_release_tarball" => release.tarball
            }
          }
        }
      ]
    }
  end

  # Resolves the single release this deployment ships, from the same
  # deterministic tarball path `mix atlas.releases.publish` uses. The
  # sha256 is computed over the tarball bytes with the same encoding as
  # `Atlas.Crates.publish_content/4`'s content_id, so consumers (e.g.
  # the ansible s3_release role) can reconstruct the published S3 key.
  # Raises when the umbrella declares zero or multiple releases, or
  # when the tarball has not been built yet.
  defp deploy_release! do
    config = Mix.Project.config()

    name =
      case config |> Keyword.get(:releases, []) |> Keyword.keys() do
        [name] ->
          name

        names ->
          raise "deployment requires exactly one release in mix.exs, got: #{inspect(names)}"
      end

    release = Mix.Release.from_config!(name, config, [])
    tarball = "#{release.name}-#{release.version}.tar.gz"
    path = Path.join(Mix.Project.build_path(), tarball)

    unless File.exists?(path) do
      raise "release tarball not found at #{path}; run `mix atlas.releases.build` first"
    end

    sha256 = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16()

    %{
      app: to_string(release.name),
      version: release.version,
      sha256: sha256,
      tarball: tarball
    }
  end
end
