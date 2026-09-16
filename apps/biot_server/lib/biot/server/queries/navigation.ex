defmodule Biot.Server.Queries.Navigation do
  @moduledoc "Builds the product counts used by the authenticated application frame."

  import Ecto.Query

  alias Biot.Server.Access
  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Principals
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Node

  @type counts :: %{biots: non_neg_integer(), nodes: non_neg_integer()}

  @spec counts(Actor.t() | nil) :: {:ok, counts()} | {:error, CommandError.t()}
  def counts(nil), do: {:error, :unauthenticated}

  def counts(%Actor{} = actor) do
    with :ok <- Principals.require_enabled(Repo, actor) do
      readable_biots = Access.readable(BiotRow, actor)

      {:ok,
       %{
         biots: Repo.aggregate(readable_biots, :count, :id),
         nodes: Repo.aggregate(from(node in Node), :count, :id)
       }}
    end
  end
end
