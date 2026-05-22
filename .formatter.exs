# Used by "mix format"
[
  inputs: ["mix.exs", "config/*.exs"],
  import_deps: [:ecto_sql],
  subdirectories: ["apps/*", "lib"]
]
