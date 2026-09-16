defmodule Biot.Server.BiotChange do
  @moduledoc "Notifies browser readers when a Biot's durable, readable state changes."

  alias Biot.Protocol.BiotId
  alias Phoenix.PubSub

  @spec topic(BiotId.t()) :: String.t()
  def topic(%BiotId{} = biot_id), do: "biot:" <> BiotId.to_string(biot_id)

  @spec changed(BiotId.t()) :: :ok | {:error, term()}
  def changed(%BiotId{} = biot_id) do
    PubSub.broadcast(Biot.Server.PubSub, topic(biot_id), {:biot_changed, biot_id})
  end

  @spec subscribe(BiotId.t()) :: :ok | {:error, term()}
  def subscribe(%BiotId{} = biot_id) do
    PubSub.subscribe(Biot.Server.PubSub, topic(biot_id))
  end

  @spec unsubscribe(BiotId.t()) :: :ok
  def unsubscribe(%BiotId{} = biot_id) do
    PubSub.unsubscribe(Biot.Server.PubSub, topic(biot_id))
  end
end
