defmodule Biot.Server.Authorization do
  @moduledoc "Owns pure authorization predicates for server application commands."

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Actor
  alias Biot.Server.Schema.Biot

  @spec owner?(Actor.t() | nil, Biot.t()) :: boolean()
  def owner?(%Actor{principal_id: principal_id}, %Biot{owner_id: principal_id}), do: true
  def owner?(_actor, %Biot{}), do: false

  @spec may_control_lifecycle?(Actor.t() | nil, Biot.t()) :: boolean()
  def may_control_lifecycle?(actor, biot), do: owner?(actor, biot)

  @spec may_change_policy?(Actor.t() | nil, Biot.t()) :: boolean()
  def may_change_policy?(actor, biot), do: owner?(actor, biot)

  @spec may_read_grants?(Actor.t() | nil, Biot.t()) :: boolean()
  def may_read_grants?(actor, biot), do: owner?(actor, biot)

  @spec may_discover?(Actor.t() | nil, Biot.t(), [PrincipalId.t()]) :: boolean()
  def may_discover?(%Actor{principal_id: principal_id} = actor, biot, shell_grants),
    do: owner?(actor, biot) or principal_id in shell_grants

  def may_discover?(nil, %Biot{}, _shell_grants), do: false
end
