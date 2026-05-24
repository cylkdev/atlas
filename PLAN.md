# Atlas Work

What to do in the [atlas](https://github.com/cylkdev/atlas) library.

## A1 — Builder container image (absorbs A2, A3, A4)

Add `priv/docker/builder/Dockerfile`. Preinstalled:

- erlang, elixir, node (versions pinned via build args)
- terraform (pinned via `ARG TERRAFORM_VERSION`)
- python3-pip, ansible, the galaxy collections from
  `priv/ansible/requirements.yml`, the pip packages from
  `priv/ansible/requirements.txt`
- aws-cli, jq, sudo, unzip, curl, ca-certificates
- AWS SSM `session-manager-plugin` (`.deb` from
  `s3.amazonaws.com/session-manager-downloads`)
- non-root `builder` user (uid 1001, gid 1001) with passwordless sudo
  via `/etc/sudoers.d/builder`; `WORKDIR /workspace` owned by builder

Add `priv/ansible/requirements.yml` and `priv/ansible/requirements.txt`
(moved from the consumer's `deploys/ansible/scripts/`).

Add `Mix.Tasks.Atlas.Builder.Image` exposing
`mix atlas.builder.image build [--push --tag <t>]`. Resolves the Dockerfile
via `Application.app_dir(:atlas, "priv/docker/builder/Dockerfile")`.

## A5 — AWS OIDC deploy-role provisioning

Vendor `priv/scripts/setup-deploy-role.sh` (moved from
`deploys/scripts/setup-deploy-role.sh`).

Add `Mix.Tasks.Atlas.Iam.SetupDeployRole` exposing
`mix atlas.iam.setup_deploy_role --repo <org/repo> --environment <name> [--region <r>]`.
Shells out to the vendored script; prints the resulting role ARN.

## B1 — erlexec shell

Configure `:erlexec` with an explicit `:shell_executable` (e.g. `/bin/sh`) so
`:exec` doesn't consult `$SHELL` at boot.

## B2 — deploy-host init (absorbs B3)

Add `Mix.Tasks.Atlas.Deploy.Init` exposing
`mix atlas.deploy.init --user <name>`. Single entry point that prepares the
host for `mix atlas.workflows.deploy`. On invocation:

1. Compiles erlexec (`mix deps.compile erlexec`) so the SUID exec-port
   binary exists on disk.
2. Installs `/etc/sudoers.d/erlexec` granting `<name>` passwordless sudo on
   that binary, via the vendored
   `priv/scripts/setup-erlexec-sudoers.sh` (moved from
   `deploys/scripts/setup-erlexec-sudoers.sh`).

Subsequent bootstrap concerns (future audit rows) extend this task rather
than adding new mix tasks.

## B4 — web asset pipeline before release

Atlas's release task walks the umbrella for any app exposing an
`assets.deploy` mix alias and runs `mix cmd --app <app> mix assets.deploy`
for each before assembling the release tarball.

## B5 — release tarball build

Add `Mix.Tasks.Atlas.Releases.Build` exposing
`mix atlas.releases.build --app <name>`. Runs B4's asset walk, then
`Mix.Tasks.Release.run(["<app>", "--overwrite"])`. Writes the tarball at the
deterministic path `mix atlas.releases.publish` expects.

## B7 — Atlas.Endpoint port

Configure `Atlas.Endpoint` to bind an atlas-owned high port (e.g. 4400) by
default instead of Phoenix's conventional 4000. Removes the consumer's need
to relocate `CylkWeb.Endpoint` via `PORT` to avoid collision.

## B8 — AtlasSchemas.Repo filesystem prep

Atlas owns the full lifecycle of `AtlasSchemas.Repo`. On boot, if the
configured adapter is `Ecto.Adapters.SQLite3`, atlas does
`File.mkdir_p!(Path.dirname(db_path))` before the repo starts. If the
adapter is Postgres, atlas does nothing. Atlas never reaches into the
consumer's repo config for a path.

## C1 — AtlasSchemas.Repo auto-migration

Atlas entry points that touch `AtlasSchemas.Repo` (`Mix.Tasks.Atlas.Releases.Publish`
and any peer) run `AtlasSchemas.Repo`'s migrations on first call:

```elixir
Ecto.Migrator.with_repo(AtlasSchemas.Repo, fn repo ->
  Ecto.Migrator.run(repo, :up, all: true)
end)
```

Cache the "already migrated this session" decision so repeated entry-point
calls don't re-check.

## D1 — AtlasSchemas.Config.repo namespace

`AtlasSchemas.Config.repo/0` reads from atlas's own app config, defaulting
to `AtlasSchemas.Repo`:

```elixir
def repo, do: Application.get_env(:atlas_schemas, :repo, AtlasSchemas.Repo)
```

The `Application.get_env(:ecto_shorts, :repo)` consultation is removed.
Atlas no longer reads from another library's config namespace.

## D2 — atlas Oban engine

Atlas derives Oban's `:engine` from the resolved repo's adapter at boot:

```elixir
engine =
  case AtlasSchemas.Config.repo().__adapter__() do
    Ecto.Adapters.SQLite3 -> Oban.Engines.Lite
    Ecto.Adapters.Postgres -> Oban.Engines.Basic
    other -> raise "Unsupported adapter for atlas Oban: #{inspect(other)}"
  end
```

The hardcoded `Oban.Engines.Lite` goes away.

## D4 — atlas reads config, never `System.get_env`

Atlas application/runtime code never calls `System.get_env` or
`System.fetch_env!`. Every value comes from `Application.get_env(:atlas, ...)`
(or `:atlas_schemas`). Env-to-config translation is the consumer's
responsibility in their `config/runtime.exs` (or `config.exs`).

Concrete first cleanups:

- `Atlas.EventBridgePlug` reads `api_key_name` and `api_key_value` from
  `Application.get_env(:atlas, Atlas.EventBridgePlug)`. No
  `System.get_env("ATLAS_EVENTBRIDGE_API_KEY_NAME")` or
  `..._VALUE` lookups in module code.
- Same rule for every other atlas module that currently reads env.

## F1 — artifact bucket consistency

Atlas's ansible role reads its release-artifact bucket from the same
`:atlas` config key that publish uses (`content_bucket`), instead of a
separately-templated `cylk-deploy-releases-<env>` name. One config value
drives both the upload (`Mix.Tasks.Atlas.Releases.Publish`) and the
download (`deploys/ansible` `s3_release` role inside atlas).

## F2 — Cloudflare tunnel for EventBridge reachability

Atlas owns the tunnel lifecycle (start before `aws.auto_scaling.listen`,
tear down on exit). Two implementations exposed, caller selects via
config:

- `Atlas.Tunnel.Named` — uses a preregistered Cloudflare named tunnel.
  Reads `Application.get_env(:atlas, Atlas.Tunnel.Named)`:
  - `:token` (the Cloudflare tunnel token)
  - `:hostname` (the public DNS pointing at the tunnel)
- `Atlas.Tunnel.Quick` — runs `cloudflared tunnel --url <local>` and
  captures the assigned `*.trycloudflare.com` URL at startup. Publishes
  that URL as the EventBridge target at runtime. No preregistration
  needed.

Selection: `Application.get_env(:atlas, :tunnel, :named)` (or equivalent
single key). Atlas's deploy task reads it and starts the corresponding
backend.

All tunnel config is read from `:atlas` app config per D4 — atlas does
not call `System.get_env` for the token or hostname.
