defmodule Atlas.Endpoint.Connection do
  @behaviour Plug

  defstruct [:plugs]

  @impl Plug
  def init(opts) do
    %__MODULE__{plugs: Keyword.fetch!(opts, :plugs)}
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, %__MODULE__{plugs: plugs}) do
    Enum.reduce(plugs, conn, fn {plug, plug_opts}, conn ->
      plug.call(conn, plug.init(plug_opts))
    end)
  end
end
