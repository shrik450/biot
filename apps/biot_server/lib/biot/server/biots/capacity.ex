defmodule Biot.Server.Biots.Capacity do
  @moduledoc "Counts capacity-holding Biots and decides whether a node has room."

  import Ecto.Query

  alias Biot.Protocol.NodeId
  alias Biot.Server.Schema.{Biot, Node, Observation}

  @spec room?(module(), Node.t()) :: boolean()
  def room?(repo, %Node{} = node) do
    count(repo, node.id) < node.max_biots
  end

  @spec counts(module(), [NodeId.t()]) :: %{NodeId.t() => non_neg_integer()}
  def counts(_repo, []), do: %{}

  def counts(repo, node_ids) do
    from(biot in Biot,
      left_join: observation in Observation,
      on: observation.biot_id == biot.id,
      where:
        biot.node_id in ^node_ids and
          (biot.desired_state != :destroyed or is_nil(observation.biot_id) or
             observation.data != :no_allocation),
      group_by: biot.node_id,
      select: {biot.node_id, count(biot.id)}
    )
    |> repo.all()
    |> Map.new()
  end

  defp count(repo, node_id), do: Map.get(counts(repo, [node_id]), node_id, 0)
end
