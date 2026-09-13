defmodule Biot.Node.Streams.Supervisor do
  @moduledoc """
  Owns the stream boundary and the node control connection as one restart unit.

  A control connection that dies without calling `disconnect/2` would otherwise leave stream groups
  alive, and a boundary that dies would leave every open unknown until the next spec. Under
  `:one_for_all`, either crash restarts both: the boundary comes back empty so every stream closes,
  and the fresh connection resynchronizes before a stream can open again.
  """

  use Supervisor

  @spec start_link([Supervisor.child_spec() | module() | {module(), term()}]) ::
          Supervisor.on_start()
  def start_link(children) do
    Supervisor.start_link(__MODULE__, children, name: __MODULE__)
  end

  @impl true
  def init(children), do: Supervisor.init(children, strategy: :one_for_all)
end
