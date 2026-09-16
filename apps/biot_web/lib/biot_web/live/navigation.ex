defmodule BiotWeb.Live.Navigation do
  @moduledoc "Loads the small counts displayed by the application navigation."

  alias Biot.Server.Actor
  alias Biot.Server.Queries.Navigation, as: NavigationQuery

  @spec counts(Actor.t()) :: %{
          biot_count: non_neg_integer() | nil,
          node_count: non_neg_integer() | nil
        }
  def counts(%Actor{} = actor) do
    case NavigationQuery.counts(actor) do
      {:ok, %{biots: biots, nodes: nodes}} -> %{biot_count: biots, node_count: nodes}
      {:error, _reason} -> %{biot_count: nil, node_count: nil}
    end
  end
end
