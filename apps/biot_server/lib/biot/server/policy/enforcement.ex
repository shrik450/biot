defmodule Biot.Server.Policy.Enforcement do
  @moduledoc "Projects whether the assigned node has applied a Biot access revision."

  alias Biot.Protocol.ConnectionId
  alias Biot.Server.NodeConnections
  alias Biot.Server.Policy
  alias Biot.Server.Schema.{Biot, Observation}

  @type freshness :: :current | :stale

  @spec freshness(Observation.t() | nil, NodeConnections.connection() | nil) :: freshness()
  def freshness(
        %Observation{connection_id: %ConnectionId{} = connection_id},
        %{connection_id: %ConnectionId{} = connection_id}
      ),
      do: :current

  def freshness(_observation, _connection), do: :stale

  @spec access(Biot.t(), Observation.t() | nil, freshness()) :: Policy.enforcement()
  def access(%Biot{} = biot, %Observation{} = observation, :current)
      when observation.applied_access_revision >= biot.access_revision do
    :applied
  end

  def access(%Biot{} = biot, _observation, _freshness), do: {:pending, biot.node_id}
end
