defmodule Atlas.ObanManager do
  @moduledoc """
  Boundary around the Atlas Oban instance.

  `supervisor_child_spec/0` returns the `{Oban, opts}` child spec that
  `Atlas.Application` supervises. Base opts declare the instance name,
  repo, queues, and plugins. Per-env overrides (`:engine`, `:testing`)
  arrive through `Application.get_env(:atlas, Oban, [])`.

  Oban's default engine is `Oban.Engines.Basic` (Postgres). Consumers
  using a SQLite-backed repo add the following to their config:

      config :atlas, Oban, engine: Oban.Engines.Lite

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

  Base opts set the instance name, repo, queue topology, and plugins.
  Per-env overrides (engine, testing mode) come in through
  `Application.get_env(:atlas, Oban, [])`.
  """
  @spec supervisor_child_spec() :: {module(), keyword()}
  def supervisor_child_spec do
    oban_opts =
      Application.get_env(@app, Oban, [])
      |> Keyword.put_new(:name, @oban_name)
      |> Keyword.put_new(:repo, AtlasSchemas.Config.repo())
      |> Keyword.put(:queues, @queues)
      |> Keyword.put_new(:plugins, @plugins)

    {Oban, oban_opts}
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
