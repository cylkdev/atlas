defmodule Atlas.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: escript(),
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
        plt_local_path: "../../dialyzer",
        plt_core_path: "../../dialyzer",
        list_unused_filters: true,
        ignore_warnings: ".dialyzer-ignore.exs",
        flags: [:unmatched_returns, :no_improper_lists]
      ]
    ]
  end

  defp escript do
    [
      main_module: Atlas.CLI,
      name: "atlas",
      app: nil
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Atlas.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:oban, "~> 2.18"},
      {:error_message, "~> 0.3"},
      {:aws, github: "cylkdev/aws", branch: "main"},
      {:elixir_exec, github: "cylkdev/elixir_exec", branch: "main"},
      {:flared, github: "cylkdev/flared", branch: "main"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:sandbox_registry, "~> 0.1", only: :test},
      {:atlas_schemas, in_umbrella: true},
      {:credo, "~> 1.4", only: [:dev, :test], runtime: false},
      {:blitz_credo_checks, "~> 0.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.10", only: :test, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
