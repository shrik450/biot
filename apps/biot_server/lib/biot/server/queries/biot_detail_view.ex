defmodule Biot.Server.Queries.BiotDetailView do
  @moduledoc "Projects the extra durable inputs needed by the Biot overview."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.RepositorySource
  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Queries.Biots
  alias Biot.Server.Queries.BiotView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Environment}

  @enforce_keys [:view, :repository, :environment]
  defstruct [:view, :repository, :environment]

  @type t :: %__MODULE__{
          view: BiotView.t(),
          repository: RepositorySource.t(),
          environment: EnvironmentSelection.t()
        }

  @spec get(Actor.t() | nil, BiotId.t()) ::
          {:ok, t()} | {:error, CommandError.t()}
  def get(actor, %BiotId{} = biot_id) do
    with {:ok, view} <- Biots.get(actor, biot_id) do
      %Biot{repository: repository} = Repo.get!(Biot, biot_id)

      %Environment{selection: environment} =
        Repo.get_by!(Environment, id: view.desired.environment_id, biot_id: biot_id)

      {:ok, %__MODULE__{view: view, repository: repository, environment: environment}}
    end
  end
end
