defmodule Biot.Server.Control.Synchronization do
  @moduledoc "Selects and builds the complete intent set sent to one node."

  import Ecto.Query

  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.NodeId
  alias Biot.Server.BiotSpecs
  alias Biot.Server.Repo
  alias Biot.Server.Schema.AccessObservation
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Observation

  @spec included?(Desired.state(), ExecutionReport.data_state() | nil) :: boolean()
  def included?(:running, _observed_data), do: true
  def included?(:stopped, _observed_data), do: true
  def included?(:destroyed, :no_allocation), do: false
  def included?(:destroyed, _observed_data), do: true

  @spec specs(NodeId.t()) :: [BiotSpec.t()]
  def specs(%NodeId{} = node_id) do
    node_biots(node_id)
    |> select([biot, observation], %{
      biot_id: biot.id,
      desired_state: biot.desired_state,
      data: observation.data
    })
    |> Repo.all()
    |> Enum.filter(&included?(&1.desired_state, &1.data))
    |> Enum.map(fn row ->
      {:ok, spec} = BiotSpecs.build(row.biot_id)
      spec
    end)
  end

  @doc """
  Returns the included Biots whose access revision is ahead of the last one the node applied.

  An application on any connection counts. Applying a revision closes every older stream on the
  node, and control loss closes every owner admitted through an older connection.
  """
  @spec access_behind(NodeId.t()) :: [Biot.Protocol.BiotId.t()]
  def access_behind(%NodeId{} = node_id) do
    node_biots(node_id)
    |> join(:left, [biot], access_observation in AccessObservation,
      on: access_observation.biot_id == biot.id
    )
    |> where(
      [biot, _observation, access_observation],
      is_nil(access_observation.applied_access_revision) or
        access_observation.applied_access_revision < biot.access_revision
    )
    |> select([biot, observation], %{
      biot_id: biot.id,
      desired_state: biot.desired_state,
      data: observation.data
    })
    |> Repo.all()
    |> Enum.filter(&included?(&1.desired_state, &1.data))
    |> Enum.map(& &1.biot_id)
  end

  @spec behind(NodeId.t(), ConnectionId.t()) :: [Biot.Protocol.BiotId.t()]
  def behind(%NodeId{} = node_id, %ConnectionId{} = connection_id) do
    from(biot in BiotRow,
      left_join: observation in Observation,
      on: observation.biot_id == biot.id,
      left_join: access_observation in AccessObservation,
      on: access_observation.biot_id == biot.id,
      where: biot.node_id == ^node_id
    )
    |> order_by([biot], asc: biot.id)
    |> select([biot, observation, access_observation], %{
      biot_id: biot.id,
      desired_state: biot.desired_state,
      desired_revision: biot.desired_revision,
      access_revision: biot.access_revision,
      data: observation.data,
      observation_connection_id: observation.connection_id,
      accepted_revision: observation.accepted_revision,
      access_connection_id: access_observation.connection_id,
      applied_access_revision: access_observation.applied_access_revision
    })
    |> Repo.all()
    |> Enum.filter(&behind?(&1, connection_id))
    |> Enum.map(& &1.biot_id)
  end

  defp node_biots(node_id) do
    from(biot in BiotRow,
      left_join: observation in Observation,
      on: observation.biot_id == biot.id,
      where: biot.node_id == ^node_id
    )
  end

  defp behind?(row, connection_id) do
    included?(row.desired_state, row.data) and
      (not accepted?(row, connection_id) or not applied?(row, connection_id))
  end

  defp accepted?(
         %{
           observation_connection_id: connection_id,
           accepted_revision: accepted_revision,
           desired_revision: desired_revision
         },
         connection_id
       ),
       do: accepted_revision >= desired_revision

  defp accepted?(_row, _connection_id), do: false

  defp applied?(
         %{
           access_connection_id: connection_id,
           applied_access_revision: applied_revision,
           access_revision: access_revision
         },
         connection_id
       ),
       do: applied_revision >= access_revision

  defp applied?(_row, _connection_id), do: false
end
