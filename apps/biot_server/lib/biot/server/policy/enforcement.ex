defmodule Biot.Server.Policy.Enforcement do
  @moduledoc "Projects whether the assigned node has applied a Biot access revision."

  alias Biot.Server.NodeConnections
  alias Biot.Server.Policy
  alias Biot.Server.Schema.{AccessObservation, Biot}

  @spec access(
          Biot.t(),
          AccessObservation.t() | nil,
          NodeConnections.connection() | nil
        ) :: Policy.enforcement()
  def access(%Biot{} = biot, %AccessObservation{} = access_observation, connection) do
    if NodeConnections.current?(access_observation.connection_id, connection) and
         access_observation.applied_access_revision >= biot.access_revision do
      :applied
    else
      {:pending, biot.node_id}
    end
  end

  def access(%Biot{} = biot, nil, _connection), do: {:pending, biot.node_id}
end
