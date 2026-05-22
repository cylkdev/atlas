# How to upload an artifact

## TL;DR

```elixir
# Release and upload my_app (version comes from mix.exs)
mix atlas.crates.publish --app my_app

# Release and upload every app in the umbrella's :releases config
mix atlas.crates.publish

# Show the latest published version of my-app
mix atlas.crates.latest --name my-app

# List every release that's been published
mix atlas.crates.list

# Download the latest published my-app into ./tmp
mix atlas.crates.download --name my-app --output ./tmp

# Point my-app's current version back at 0.1.0
mix atlas.crates.set --name my-app --version 0.1.0

# Build a release without uploading
mix atlas.releases.build --app my_app
```

This guide walks you through releasing one of your apps and working with the published artifacts.

## One-time setup

Before you publish anything, do three things from the umbrella root. Set up the database with `mix ecto.setup`. Set your storage bucket in `config/config.exs` by adding `config :atlas, bucket: "atlas-dev"`. Then open the umbrella's `mix.exs` and, inside `project/0`, add a `releases:` entry for each app you want to publish:

```elixir
releases: [
  my_app: [version: "0.1.0", applications: [my_app: :permanent]]
]
```

This tells the release system which apps exist and what to call them.

## Publish your app

Run this one command:

```
mix atlas.crates.publish --app my_app
```

This releases your app and uploads it in one step — you don't have to run `mix release` yourself first. The version is taken from your `:releases` entry in `mix.exs` (falling back to `"unknown"` if not set). The release is recorded under the same name as the OTP app.

You can pass `--app` more than once to publish several apps in one go. If you leave `--app` off entirely, every app in your `:releases` config gets published.

When it finishes you'll see a content ID confirming the upload succeeded.

## Look up what's published

To see the latest version of one app, run `mix atlas.crates.latest --name my-app`. To see everything, run `mix atlas.crates.list`.

## Download it back

To pull a published release down to your machine, run `mix atlas.crates.download --name my-app --output ./tmp`. This grabs the latest published version of `my-app` and writes it into the `./tmp` directory. To download a specific publish instead of the latest, add `--content-id` with the ID you got from `crates.latest` or `crates.list`.

## Roll back to an earlier version

If a publish goes bad and you want the current version to point at an earlier publish, run `mix atlas.crates.set --name my-app --version 0.1.0`. This updates `my-app` so that `crates.latest` reports the version you specified. The version you pass must have been published previously.

## Just release without uploading

If for some reason you want to build the release without uploading, run `mix atlas.releases.build --app my_app`. Pass `--app` more than once to release several apps at once, or leave it off to release every app in your `releases:` config.

## Troubleshooting

If you get `--name is required`, you skipped a flag — every option here uses `--flag value` form. If you get a `:nxdomain` error, your bucket isn't configured; go back to the setup section. If you get `no :releases configured`, you need to add the `releases:` entry to the umbrella `mix.exs`. If `crates.latest` says the release has no current content, you haven't published yet — run `crates.publish` first.
