defmodule Biot.Server.Queries.AccessDisplayView do
  @moduledoc "Projects owner-readable access grants with last-known principal identity."

  import Ecto.Query

  alias Biot.Protocol.{BiotId, Port, PrincipalId}
  alias Biot.Server.Access
  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Queries.AccessView
  alias Biot.Server.Queries.PrincipalView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Principal

  defmodule Grant do
    @moduledoc "One explicit shell or publication-view grant with its principal identity."

    @enforce_keys [:kind, :principal]
    defstruct [:kind, :principal]

    @type kind :: :shell | {:view, Port.t()}
    @type t :: %__MODULE__{kind: kind(), principal: PrincipalView.t()}
  end

  @enforce_keys [:owner, :grants]
  defstruct [:owner, :grants]

  @type t :: %__MODULE__{owner: PrincipalView.t(), grants: [Grant.t()]}

  @spec get(Actor.t() | nil, BiotId.t()) ::
          {:ok, t()} | {:error, CommandError.t()}
  def get(actor, %BiotId{} = biot_id) do
    with {:ok, access} <- Access.get_grants(actor, biot_id) do
      principals = principal_map(access)

      {:ok,
       %__MODULE__{
         owner: Map.fetch!(principals, access.owner_id),
         grants: grants(access, principals)
       }}
    end
  end

  defp principal_map(%AccessView{} = access) do
    access
    |> principal_ids()
    |> then(fn ids ->
      from(principal in Principal, where: principal.id in ^ids)
      |> Repo.all()
      |> Map.new(fn principal -> {principal.id, PrincipalView.project(principal)} end)
    end)
  end

  defp principal_ids(%AccessView{} = access) do
    [access.owner_id | access.shell_grants ++ Enum.map(access.view_grants, & &1.principal_id)]
    |> Enum.uniq()
  end

  defp grants(%AccessView{} = access, principals) do
    shell_grants =
      Enum.map(access.shell_grants, fn %PrincipalId{} = principal_id ->
        %Grant{kind: :shell, principal: Map.fetch!(principals, principal_id)}
      end)

    view_grants =
      Enum.map(access.view_grants, fn %{port: %Port{} = port, principal_id: principal_id} ->
        %Grant{kind: {:view, port}, principal: Map.fetch!(principals, principal_id)}
      end)

    shell_grants ++ view_grants
  end
end
