defmodule Biot.Server.FetchCredentials do
  @moduledoc """
  Delivers and removes the source credentials a node needs to fetch a private checkout or layer.

  A source credential never enters the runtime and never reaches the server's database, so unlike a
  runtime secret it sets no exposure marker: nothing the biot runs can have seen it. The value is
  scoped to one parsed HTTPS source by `Biot.Protocol.RepositorySource`, and to one HTTP field
  value by `Biot.Protocol.AuthorizationValue`, before it reaches this module.

  There is no queue here. A credential the assigned node cannot be told about right now is one the
  owner delivers again; holding it would mean holding the value.
  """

  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.RepositorySource
  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Control.Connection
  alias Biot.Server.Delivery

  @spec deliver(Actor.t() | nil, BiotId.t(), RepositorySource.t(), AuthorizationValue.t()) ::
          :ok | {:error, CommandError.t()}
  def deliver(actor, %BiotId{} = biot_id, %RepositorySource{} = source, value) do
    with {:ok, {pid, timeout_ms}} <- Delivery.to_assigned_node(actor, biot_id) do
      Connection.deliver_fetch_credential(pid, biot_id, source, value, timeout_ms)
    end
  end

  @spec remove(Actor.t() | nil, BiotId.t(), RepositorySource.t()) ::
          :ok | {:error, CommandError.t()}
  def remove(actor, %BiotId{} = biot_id, %RepositorySource{} = source) do
    with {:ok, {pid, timeout_ms}} <- Delivery.to_assigned_node(actor, biot_id) do
      Connection.remove_fetch_credential(pid, biot_id, source, timeout_ms)
    end
  end
end
