defmodule Biot.Server.Secrets do
  @moduledoc """
  Delivers, removes, and lists a biot's runtime secrets through its assigned node.

  The server holds no value. It records only that one may have reached the biot, and it records
  that before the value is sent: a delivery that fails, times out, or loses its reply has still
  put the value where it might have landed, so the marker has to be true in every one of those
  cases. Neither removal nor destruction clears it, because exposure cannot be undone.
  """

  import Ecto.Query

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretValue
  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Control.Connection
  alias Biot.Server.Delivery
  alias Biot.Server.Queries.SecretView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow

  @spec deliver(Actor.t() | nil, BiotId.t(), SecretName.t(), SecretValue.t()) ::
          :ok | {:error, CommandError.t()}
  def deliver(nil, %BiotId{}, %SecretName{}, _value), do: {:error, :unauthenticated}

  def deliver(%Actor{} = actor, %BiotId{} = biot_id, %SecretName{} = name, value) do
    with {:ok, {pid, timeout_ms}} <- mark_exposure(actor, biot_id) do
      Connection.deliver_secret(pid, biot_id, name, value, timeout_ms)
    end
  end

  @spec remove(Actor.t() | nil, BiotId.t(), SecretName.t()) :: :ok | {:error, CommandError.t()}
  def remove(actor, %BiotId{} = biot_id, %SecretName{} = name) do
    with {:ok, {pid, timeout_ms}} <- Delivery.to_assigned_node(actor, biot_id) do
      Connection.remove_secret(pid, biot_id, name, timeout_ms)
    end
  end

  @spec list(Actor.t() | nil, BiotId.t()) ::
          {:ok, [SecretView.t()]} | {:error, CommandError.t()}
  def list(actor, %BiotId{} = biot_id) do
    with {:ok, {pid, timeout_ms}} <- Delivery.to_assigned_node(actor, biot_id),
         {:ok, names} <- Connection.list_secrets(pid, biot_id, timeout_ms) do
      {:ok, Enum.map(names, &SecretView.project/1)}
    end
  end

  # The marker is committed on its own, before anything is sent, so every later outcome including
  # a crash leaves it true. It is set only once the assigned node is ready to take the value, so an
  # unreachable node leaves no marker for a value that was never sent.
  defp mark_exposure(actor, biot_id) do
    Repo.transaction(
      fn ->
        with {:ok, biot} <- Delivery.owned_biot(actor, biot_id),
             {:ok, connection} <- Delivery.connection(biot) do
          Repo.update_all(
            from(row in BiotRow, where: row.id == ^biot.id),
            set: [direct_secret_exposure_possible: true, updated_at: DateTime.utc_now()]
          )

          connection
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
  end
end
