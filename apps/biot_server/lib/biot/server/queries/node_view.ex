defmodule Biot.Server.Queries.NodeView do
  @moduledoc "Projects one node with its capacity, connection, and latest orphan report."

  alias Biot.Protocol.NodeId
  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Protocol.Platform
  alias Biot.Server.NodeConnections
  alias Biot.Server.Nodes.Status
  alias Biot.Server.Schema.{Node, NodeObservation}

  defmodule Input do
    @moduledoc "Lists every durable and live value required to project one node view."

    @enforce_keys [:node, :assigned_biots, :connection, :observation]
    defstruct [:node, :assigned_biots, :connection, :observation]

    @type t :: %__MODULE__{
            node: Node.t(),
            assigned_biots: non_neg_integer(),
            connection: NodeConnections.connection() | nil,
            observation: NodeObservation.t() | nil
          }
  end

  @enforce_keys [:id, :status, :platform, :max_biots, :assigned_biots, :connection, :orphans]
  defstruct [:id, :status, :platform, :max_biots, :assigned_biots, :connection, :orphans]

  @type orphans ::
          :never_reported
          | %{reported_at: DateTime.t(), allocations: [OrphanedAllocation.t()]}

  @type t :: %__MODULE__{
          id: NodeId.t(),
          status: Status.t(),
          platform: Platform.t() | nil,
          max_biots: pos_integer(),
          assigned_biots: non_neg_integer(),
          connection: :connecting | :ready | :unavailable,
          orphans: orphans()
        }

  @spec project(Input.t()) :: t()
  def project(%Input{} = input) do
    %__MODULE__{
      id: input.node.id,
      status: input.node.status,
      platform: input.node.platform,
      max_biots: input.node.max_biots,
      assigned_biots: input.assigned_biots,
      connection: connection(input.connection),
      orphans: orphans(input.observation)
    }
  end

  defp connection(nil), do: :unavailable
  defp connection(%{state: :synchronizing}), do: :connecting
  defp connection(%{state: :ready}), do: :ready

  defp orphans(nil), do: :never_reported

  defp orphans(%NodeObservation{} = observation) do
    %{reported_at: observation.received_at, allocations: observation.orphaned_allocations}
  end
end
