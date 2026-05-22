defmodule Atlas.Runtime do
  use Supervisor

  @default_name __MODULE__

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, Keyword.put_new(opts, :name, @default_name))
  end

  def init(opts) do
    children = [{Atlas.SdNotify, opts}]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
