defmodule Biot.Server.Policy.Transaction do
  @moduledoc "Runs one immediate transaction for a synchronous policy change."

  alias Biot.Protocol.BiotId
  alias Biot.Server.Access.Withdrawal
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.CommandError
  alias Biot.Server.NodeConnections
  alias Biot.Server.Policy
  alias Biot.Server.Policy.{Applied, Enforcement, Unchanged}
  alias Biot.Server.Principals
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{AccessObservation, Biot}

  @type change ::
          :unchanged
          | {:added, Ecto.Multi.t()}
          | {:withdrawn, Ecto.Multi.t()}
          | {:error, CommandError.t()}

  @spec execute(Actor.t(), BiotId.t(), (module(), Biot.t() -> change())) :: Policy.result()
  def execute(%Actor{} = actor, %BiotId{} = biot_id, change) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:policy, fn repo, _changes -> plan(repo, actor, biot_id, change) end)
    |> Ecto.Multi.merge(&writes/1)
    |> Repo.transaction(mode: :immediate)
    |> transaction_result()
  end

  defp plan(repo, actor, biot_id, change) do
    with :ok <- Principals.require_enabled(repo, actor),
         {:ok, biot} <- load_biot(repo, biot_id),
         :ok <- authorize(actor, biot),
         :ok <- require_live(biot) do
      normalize(change.(repo, biot), biot)
    end
  end

  defp normalize(:unchanged, biot), do: {:ok, {:unchanged, biot}}
  defp normalize({:added, %Ecto.Multi{} = multi}, biot), do: {:ok, {:added, biot, multi}}

  defp normalize({:withdrawn, %Ecto.Multi{} = multi}, biot),
    do: {:ok, {:withdrawn, biot, multi}}

  defp normalize({:error, error}, _biot), do: {:error, error}

  defp writes(%{policy: {:unchanged, %Biot{} = biot}}) do
    Ecto.Multi.new()
    |> Ecto.Multi.put(:biot, biot)
  end

  defp writes(%{policy: {:added, %Biot{} = biot, %Ecto.Multi{} = multi}}) do
    Ecto.Multi.put(multi, :biot, biot)
  end

  defp writes(%{policy: {:withdrawn, %Biot{} = biot, %Ecto.Multi{} = multi}}) do
    Ecto.Multi.update(
      multi,
      :biot,
      Ecto.Changeset.change(biot, access_revision: biot.access_revision + 1)
    )
  end

  defp transaction_result({:ok, %{policy: {kind, _biot}, biot: %Biot{} = biot}}) do
    build_result(kind, biot)
  end

  defp transaction_result({:ok, %{policy: {kind, _biot, _multi}, biot: %Biot{} = biot}}) do
    build_result(kind, biot)
  end

  defp transaction_result({:error, :policy, error, _changes}), do: {:error, error}

  defp transaction_result({:error, _operation, %Ecto.Changeset{} = changeset, _changes}) do
    raise Ecto.InvalidChangesetError,
      action: changeset.action || :insert,
      changeset: changeset
  end

  defp transaction_result({:error, _operation, error, _changes}), do: {:error, error}

  defp build_result(kind, %Biot{} = biot) do
    if kind == :withdrawn do
      Withdrawal.enforce([{:biot, biot.id}], [{biot.node_id, biot.id}])
    end

    # Enforcement uses committed state because an earlier withdrawal can still be pending.
    access_observation = Repo.get(AccessObservation, biot.id)
    connection = NodeConnections.current(biot.node_id)

    result = %{
      biot_id: biot.id,
      access_revision: biot.access_revision,
      enforcement: Enforcement.access(biot, access_observation, connection)
    }

    case kind do
      :unchanged -> {:ok, struct!(Unchanged, result)}
      kind when kind in [:added, :withdrawn] -> {:ok, struct!(Applied, result)}
    end
  end

  defp load_biot(repo, biot_id) do
    case repo.get(Biot, biot_id) do
      nil -> {:error, :not_found}
      %Biot{} = biot -> {:ok, biot}
    end
  end

  defp authorize(actor, %Biot{} = biot) do
    if Authorization.may_change_policy?(actor, biot), do: :ok, else: {:error, :forbidden}
  end

  defp require_live(%Biot{} = biot) do
    if Biot.desired(biot).state == :destroyed, do: {:error, :destroyed}, else: :ok
  end
end
