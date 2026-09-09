defmodule Biot.Server.Queries.BiotView do
  @moduledoc "Projects durable biot records and live connection state into product-facing data."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.Port
  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Policy
  alias Biot.Server.Policy.Enforcement
  alias Biot.Server.Queries.OperationView
  alias Biot.Server.Schema.{Biot, Node, Observation, Operation}

  defmodule Input do
    @moduledoc "Lists every durable and live value required to project one Biot view."

    alias Biot.Server.NodeConnections
    alias Biot.Server.Schema.{Biot, Node, Observation, Operation}

    @enforce_keys [
      :biot,
      :observation,
      :node,
      :operation,
      :connection,
      :publications,
      :direct_secrets_ever_delivered
    ]
    defstruct [
      :biot,
      :observation,
      :node,
      :operation,
      :connection,
      :publications,
      :direct_secrets_ever_delivered
    ]

    @type t :: %__MODULE__{
            biot: Biot.t(),
            observation: Observation.t() | nil,
            node: Node.t(),
            operation: Operation.t() | nil,
            connection: NodeConnections.connection() | nil,
            publications: list(),
            direct_secrets_ever_delivered: boolean()
          }
  end

  @enforce_keys [
    :id,
    :name,
    :owner_id,
    :node_id,
    :desired,
    :actual,
    :node,
    :operation,
    :access,
    :publications,
    :direct_secrets_ever_delivered
  ]
  defstruct [
    :id,
    :name,
    :owner_id,
    :node_id,
    :desired,
    :actual,
    :node,
    :operation,
    :access,
    :publications,
    :direct_secrets_ever_delivered
  ]

  @type t :: %__MODULE__{
          id: BiotId.t(),
          name: String.t(),
          owner_id: PrincipalId.t(),
          node_id: NodeId.t(),
          desired: Desired.t(),
          actual: :never_reported | map(),
          node: :connecting | :ready | :unavailable | :disabled | :retired,
          operation: OperationView.t() | nil,
          access: %{revision: pos_integer(), enforcement: Policy.enforcement()},
          publications: [%{port: Port.t(), url: String.t()}],
          direct_secrets_ever_delivered: boolean()
        }

  @spec project(Input.t()) :: t()
  def project(%Input{
        biot: %Biot{} = biot,
        observation: observation,
        node: %Node{} = node,
        operation: operation,
        connection: connection,
        publications: publications,
        direct_secrets_ever_delivered: direct_secrets_ever_delivered
      }) do
    freshness = Enforcement.freshness(observation, connection)

    %__MODULE__{
      id: biot.id,
      name: biot.name,
      owner_id: biot.owner_id,
      node_id: biot.node_id,
      desired: Biot.desired(biot),
      actual: actual(observation, freshness),
      node: node_status(node.status, connection_state(connection)),
      operation: operation(operation),
      access: %{
        revision: biot.access_revision,
        enforcement: Enforcement.access(biot, observation, freshness)
      },
      publications: publications,
      direct_secrets_ever_delivered: direct_secrets_ever_delivered
    }
  end

  defp actual(nil, _freshness), do: :never_reported

  defp actual(%Observation{} = observation, freshness) do
    %{
      received_at: observation.received_at,
      freshness: freshness,
      installed_environment: observation.installed_environment_id,
      container: observation.container,
      data: observation.data,
      failure: observation.failure
    }
  end

  defp node_status(:disabled, _connection_state), do: :disabled
  defp node_status(:retired, _connection_state), do: :retired
  defp node_status(:enabled, :synchronizing), do: :connecting
  defp node_status(:enabled, :ready), do: :ready
  defp node_status(:enabled, nil), do: :unavailable

  defp operation(nil), do: nil
  defp operation(%Operation{} = operation), do: OperationView.project(operation)

  defp connection_state(nil), do: nil
  defp connection_state(%{state: state}), do: state
end
