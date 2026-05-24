defmodule Atlas.Deploy do
  @moduledoc """
  Deploy-pipeline operations invoked from the Atlas CLI / Mix tasks.

  Submodules implement individual deploy primitives. Each is callable
  as a library function and also exposed through a `Mix.Tasks.Atlas.Deploy.*`
  task.
  """
end
