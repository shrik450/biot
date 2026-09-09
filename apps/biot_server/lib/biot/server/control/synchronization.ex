defmodule Biot.Server.Control.Synchronization do
  @moduledoc "Selects and builds the complete intent set sent to one node."

  import Ecto.Query

  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.NodeId
  alias Biot.Server.Biots
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Observation}

  @spec included?(atom(), atom() | nil) :: boolean()
  def included?(state, _observed_data) when state != :destroyed, do: true
  def included?(:destroyed, :no_allocation), do: false
  def included?(:destroyed, _observed_data), do: true

  @spec specs(NodeId.t()) :: [BiotSpec.t()]
  def specs(%NodeId{} = node_id) do
    from(biot in Biot,
      left_join: observation in Observation,
      on: observation.biot_id == biot.id,
      where: biot.node_id == ^node_id,
      select: {biot.id, biot.desired_state, observation.data}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, state, data} -> included?(state, data) end)
    |> Enum.map(fn {biot_id, _state, _data} ->
      {:ok, spec} = Biots.spec(biot_id)
      spec
    end)
  end
end
