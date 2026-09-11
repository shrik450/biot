defmodule Biot.Server.Delivery do
  @moduledoc """
  The rules every secret and fetch credential request shares, in one place.

  A request needs the current owner, a biot that is not destroyed, and the assigned node's ready
  connection. Anything else the caller learns is `temporarily_unavailable`, because a node the
  server cannot reach is a state that passes rather than a fault the owner can act on. That is also
  why an offline node never yields an empty list: there is no answer to give, only no answer.

  `owned_biot/2` reads through `Biot.Server.Access`, so which biots exist for an actor stays one
  rule, and it runs inside a caller's transaction because the repository is bound to the process.
  `Biot.Server.Secrets.deliver/4` is the one caller that needs that, because the exposure marker
  has to be committed before a value is sent.
  """

  alias Biot.Protocol.BiotId
  alias Biot.Server.Access
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.CommandError
  alias Biot.Server.NodeConnections
  alias Biot.Server.Schema.Biot, as: BiotRow

  @typedoc "The connection to send one request over, and how long the caller waits for its reply."
  @type target :: {pid(), pos_integer()}

  @spec to_assigned_node(Actor.t() | nil, BiotId.t()) ::
          {:ok, target()} | {:error, CommandError.t()}
  def to_assigned_node(nil, %BiotId{}), do: {:error, :unauthenticated}

  def to_assigned_node(%Actor{} = actor, %BiotId{} = biot_id) do
    with {:ok, biot} <- owned_biot(actor, biot_id), do: connection(biot)
  end

  @spec owned_biot(Actor.t(), BiotId.t()) :: {:ok, BiotRow.t()} | {:error, CommandError.t()}
  def owned_biot(%Actor{} = actor, %BiotId{} = biot_id) do
    with {:ok, biot, _role} <- Access.fetch_readable(actor, biot_id),
         :ok <- require_owner(actor, biot),
         :ok <- require_live(biot) do
      {:ok, biot}
    end
  end

  @spec connection(BiotRow.t()) :: {:ok, target()} | {:error, :temporarily_unavailable}
  def connection(%BiotRow{} = biot) do
    with {:ok, pid} <- NodeConnections.ready(biot.node_id), do: {:ok, {pid, timeout_ms()}}
  end

  defp require_owner(actor, biot) do
    if Authorization.owner?(actor, biot), do: :ok, else: {:error, :forbidden}
  end

  defp require_live(biot) do
    if BiotRow.desired(biot).state == :destroyed, do: {:error, :destroyed}, else: :ok
  end

  defp timeout_ms, do: Application.fetch_env!(:biot_server, :node_request_timeout_ms)
end
