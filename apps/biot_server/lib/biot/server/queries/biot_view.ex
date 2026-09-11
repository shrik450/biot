defmodule Biot.Server.Queries.BiotView do
  @moduledoc "Projects durable biot records and live connection state into product-facing data."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.Port
  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Authorization
  alias Biot.Server.NodeConnections
  alias Biot.Server.Policy
  alias Biot.Server.Policy.Enforcement
  alias Biot.Server.Queries.OperationView
  alias Biot.Server.Schema.{AccessObservation, Node, Observation, Operation}
  alias Biot.Server.Schema.Biot, as: BiotRow

  defmodule Input do
    @moduledoc "Lists every durable and live value required to project one Biot view."

    @enforce_keys [
      :biot,
      :role,
      :observation,
      :access_observation,
      :node,
      :operation,
      :connection,
      :publications
    ]
    defstruct [
      :biot,
      :role,
      :observation,
      :access_observation,
      :node,
      :operation,
      :connection,
      :publications
    ]

    @type t :: %__MODULE__{
            biot: BiotRow.t(),
            role: Authorization.role(),
            observation: Observation.t() | nil,
            access_observation: AccessObservation.t() | nil,
            node: Node.t(),
            operation: Operation.t() | nil,
            connection: NodeConnections.connection() | nil,
            publications: list()
          }
  end

  @enforce_keys [
    :id,
    :name,
    :owner_id,
    :node_id,
    :role,
    :desired,
    :actual,
    :node,
    :operation,
    :access,
    :publications,
    :direct_secret_exposure_possible
  ]
  defstruct [
    :id,
    :name,
    :owner_id,
    :node_id,
    :role,
    :desired,
    :actual,
    :node,
    :operation,
    :access,
    :publications,
    :direct_secret_exposure_possible
  ]

  @type t :: %__MODULE__{
          id: BiotId.t(),
          name: String.t(),
          owner_id: PrincipalId.t(),
          node_id: NodeId.t(),
          role: Authorization.role(),
          desired: Desired.t(),
          actual: :never_reported | map(),
          node: :connecting | :ready | :unavailable | :disabled | :retired | :abandoned,
          operation: OperationView.t() | nil,
          access: %{revision: pos_integer(), enforcement: Policy.enforcement()},
          publications: [%{port: Port.t(), url: String.t()}],
          direct_secret_exposure_possible: boolean()
        }

  @spec project(Input.t()) :: t()
  def project(%Input{
        biot: %BiotRow{} = biot,
        role: role,
        observation: observation,
        access_observation: access_observation,
        node: %Node{} = node,
        operation: operation,
        connection: connection,
        publications: publications
      }) do
    %__MODULE__{
      id: biot.id,
      name: biot.name,
      owner_id: biot.owner_id,
      node_id: biot.node_id,
      role: role,
      desired: BiotRow.desired(biot),
      actual: actual(observation, connection),
      node: node_status(node.status, connection_state(connection)),
      operation: operation(operation),
      access: %{
        revision: biot.access_revision,
        enforcement: Enforcement.access(biot, access_observation, connection)
      },
      publications: publications,
      direct_secret_exposure_possible: biot.direct_secret_exposure_possible
    }
  end

  defp actual(nil, _connection), do: :never_reported

  defp actual(%Observation{} = observation, connection) do
    freshness =
      if NodeConnections.current?(observation.connection_id, connection),
        do: :current,
        else: :stale

    %{
      received_at: observation.received_at,
      freshness: freshness,
      installed_environment: observation.installed_environment_id,
      container: observation.container,
      data: observation.data,
      waiting_for: observation.waiting_for,
      failure: observation.failure
    }
  end

  defp node_status(:disabled, _connection_state), do: :disabled
  defp node_status(:retired, _connection_state), do: :retired
  defp node_status(:abandoned, _connection_state), do: :abandoned
  defp node_status(:enabled, :synchronizing), do: :connecting
  defp node_status(:enabled, :ready), do: :ready
  defp node_status(:enabled, nil), do: :unavailable

  defp operation(nil), do: nil
  defp operation(%Operation{} = operation), do: OperationView.project(operation)

  defp connection_state(nil), do: nil
  defp connection_state(%{state: state}), do: state
end
