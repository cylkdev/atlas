defmodule Atlas.ObanManager do
  @moduledoc """
  Boundary around the Atlas Oban instance.

  `supervisor_child_spec/0` returns the `{Oban, opts}` child spec that
  `Atlas.Application` supervises. Base opts declare the instance name,
  repo, engine, queues, and plugins. Per-env overrides (e.g.
  `:testing`) arrive through `Application.get_env(:atlas, Oban, [])`.

  ## Engine selection (PLAN.md D2)

  The Oban engine is **derived at runtime** from the resolved repo's
  adapter, not hardcoded and not read from consumer config:

    * `Ecto.Adapters.SQLite3` → `Oban.Engines.Lite`
    * `Ecto.Adapters.Postgres` → `Oban.Engines.Basic`
    * anything else → raises with the unsupported adapter name

  Consumers that previously had to write
  `config :atlas, Oban, engine: Oban.Engines.Lite` in their own
  `config.exs` can delete that line — Atlas figures it out from
  `AtlasSchemas.Config.repo().__adapter__()`. A consumer who still
  explicitly sets `:engine` via `config :atlas, Oban, engine: ...`
  wins (the user's explicit override is honored).

  `insert_job/3` is the single insertion point for all Atlas Oban jobs.
  No other module references `Oban.*` directly, apart from worker
  `use Oban.Worker` declarations.
  """

  # `Oban.Job.new/2` raises on unknown option keys. This allow-list keeps
  # unrelated insert options out of the worker changeset builder.
  # See https://hexdocs.pm/oban/Oban.Job.html#new/2
  @oban_job_option_keys [
    :max_attempts,
    :meta,
    :priority,
    :queue,
    :replace,
    :scheduled_at,
    :schedule_in,
    :tags,
    :unique,
    :worker
  ]

  @app :atlas
  @oban_name Application.compile_env!(@app, :oban_name)
  @queues [stripe: 10]
  @plugins [Oban.Plugins.Pruner]

  @doc """
  Returns the `{Oban, opts}` child spec that `Atlas.Application` supervises.

  Base opts set the instance name, repo, engine (derived from the
  repo's adapter — see `engine_for_adapter!/1`), queue topology, and
  plugins. Per-env overrides come in through
  `Application.get_env(:atlas, Oban, [])`. An explicit `:engine` in
  that config takes precedence over the derived value, so a consumer
  can still pin the engine if they need to.
  """
  @spec supervisor_child_spec() :: {module(), keyword()}
  def supervisor_child_spec do
    repo = AtlasSchemas.Config.repo()
    derived_engine = engine_for_adapter!(repo.__adapter__())

    oban_opts =
      Application.get_env(@app, Oban, [])
      |> Keyword.put_new(:name, @oban_name)
      |> Keyword.put_new(:repo, repo)
      |> Keyword.put_new(:engine, derived_engine)
      |> Keyword.put(:queues, @queues)
      |> Keyword.put_new(:plugins, @plugins)

    {Oban, oban_opts}
  end

  @doc """
  Maps an Ecto adapter module to the Oban engine that supports it.

  Raises `ArgumentError` for any adapter Atlas does not support so a
  misconfigured deploy fails loudly at boot rather than silently
  selecting the wrong engine.
  """
  @spec engine_for_adapter!(module()) :: module()
  def engine_for_adapter!(Ecto.Adapters.SQLite3), do: Oban.Engines.Lite
  def engine_for_adapter!(Ecto.Adapters.Postgres), do: Oban.Engines.Basic

  def engine_for_adapter!(other) do
    raise ArgumentError,
          "Unsupported adapter for Atlas Oban: #{inspect(other)}. " <>
            "Atlas supports Ecto.Adapters.Postgres and Ecto.Adapters.SQLite3."
  end

  @doc """
  Builds and inserts an Oban job for `worker`.

  Options accepted by `Oban.Job.new/2` (`:queue`, `:max_attempts`,
  `:schedule_in`, `:unique`, etc.) are forwarded to the worker changeset
  builder. The full unmodified `opts` is then passed to `Oban.insert/3`.

  Returns `{:ok, job}` on success, `{:error, reason}` otherwise.
  """
  @spec insert_job(module(), Oban.Job.args(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Oban.Job.changeset() | term()}
  def insert_job(worker, params, opts \\ []) do
    changeset = worker.new(params, Keyword.take(opts, @oban_job_option_keys))
    Oban.insert(@oban_name, changeset, opts)
  end
end
