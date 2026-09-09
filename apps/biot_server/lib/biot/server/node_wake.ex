defmodule Biot.Server.NodeWake do
  @moduledoc "Owns the best-effort wake channel between lifecycle commands and node connections."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.NodeId
  alias Phoenix.PubSub

  @spec topic(NodeId.t()) :: String.t()
  def topic(%NodeId{} = node_id), do: "node:" <> NodeId.to_string(node_id)

  @spec spec_changed(NodeId.t(), BiotId.t()) :: :ok | {:error, term()}
  def spec_changed(%NodeId{} = node_id, %BiotId{} = biot_id) do
    PubSub.broadcast(Biot.Server.PubSub, topic(node_id), {:biot_spec_changed, biot_id})
  end

  @spec subscribe(NodeId.t()) :: :ok | {:error, term()}
  def subscribe(%NodeId{} = node_id) do
    PubSub.subscribe(Biot.Server.PubSub, topic(node_id))
  end
end
