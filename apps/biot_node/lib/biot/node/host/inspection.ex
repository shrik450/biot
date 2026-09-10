defmodule Biot.Node.Host.Inspection do
  @moduledoc "The five host facts that the controller joins with its own state."

  alias Biot.Node.NodeState
  alias Biot.Protocol.EnvironmentId

  @enforce_keys [:data, :resolutions, :installation, :container, :prepared]
  defstruct [:data, :resolutions, :installation, :container, :prepared]

  @type t :: %__MODULE__{
          data: NodeState.data_state(),
          resolutions: %{EnvironmentId.t() => NodeState.resolution_state()},
          installation: NodeState.installation_state(),
          container: NodeState.resource(NodeState.container()),
          prepared: NodeState.prepared()
        }
end
