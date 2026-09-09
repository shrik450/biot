defmodule Biot.Server.Queries.AccessView do
  @moduledoc "Projects explicit access records into the grants view."

  alias Biot.Protocol.Port
  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Schema.{Biot, ShellGrant, ViewGrant}

  defmodule Input do
    @moduledoc "Lists every row required to project one access view."

    alias Biot.Server.Schema.{Biot, ShellGrant, ViewGrant}

    @enforce_keys [:biot, :shell_grants, :view_grants]
    defstruct [:biot, :shell_grants, :view_grants]

    @type t :: %__MODULE__{
            biot: Biot.t(),
            shell_grants: [ShellGrant.t()],
            view_grants: [ViewGrant.t()]
          }
  end

  @enforce_keys [:owner_id, :shell_grants, :view_grants]
  defstruct [:owner_id, :shell_grants, :view_grants]

  @type t :: %__MODULE__{
          owner_id: PrincipalId.t(),
          shell_grants: [PrincipalId.t()],
          view_grants: [%{port: Port.t(), principal_id: PrincipalId.t()}]
        }

  @spec project(Input.t()) :: t()
  def project(%Input{
        biot: %Biot{owner_id: owner_id},
        shell_grants: shell_grants,
        view_grants: view_grants
      }) do
    %__MODULE__{
      owner_id: owner_id,
      shell_grants:
        shell_grants
        |> Enum.map(& &1.principal_id)
        |> Enum.sort_by(&PrincipalId.to_string/1),
      view_grants:
        view_grants
        |> Enum.map(fn grant -> %{port: grant.port, principal_id: grant.principal_id} end)
        |> Enum.sort_by(fn grant ->
          {grant.port.value, PrincipalId.to_string(grant.principal_id)}
        end)
    }
  end
end
