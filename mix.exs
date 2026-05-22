defmodule AtlasUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        doctor: :test,
        coverage: :test,
        dialyzer: :test,
        coveralls: :test,
        "coveralls.lcov": :test,
        "coveralls.json": :test,
        "coveralls.html": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test
      ],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_ignore_apps: [],
        plt_local_path: "dialyzer",
        plt_core_path: "dialyzer",
        list_unused_filters: true,
        ignore_warnings: ".dialyzer-ignore.exs",
        flags: [:unmatched_returns, :no_improper_lists]
      ]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      {:credo, "~> 1.4", only: [:dev, :test], runtime: false},
      {:blitz_credo_checks, "~> 0.1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.13", only: :test, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:aws, github: "cylkdev/aws", branch: "main"},
      {:elixir_exec, github: "cylkdev/elixir_exec", branch: "main"},
      {:flared, github: "cylkdev/flared", branch: "main"}
    ]
  end

  # Forwards the standard Ecto mix tasks from the umbrella root to the
  # `atlas_schemas` app, which owns `AtlasSchemas.Repo`. This lets us run
  # `mix ecto.create`, `mix ecto.migrate`, etc. from the umbrella root
  # without changing directory.
  defp aliases do
    [
      "ecto.create": ["do --app atlas_schemas ecto.create"],
      "ecto.drop": ["do --app atlas_schemas ecto.drop"],
      "ecto.migrate": ["do --app atlas_schemas ecto.migrate"],
      "ecto.rollback": ["do --app atlas_schemas ecto.rollback"],
      "ecto.gen.migration": ["do --app atlas_schemas ecto.gen.migration"],
      "ecto.migrations": ["do --app atlas_schemas ecto.migrations"],
      "ecto.dump": ["do --app atlas_schemas ecto.dump"],
      "ecto.load": ["do --app atlas_schemas ecto.load"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
