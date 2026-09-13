defmodule Biot.Server.Authorization do
  @moduledoc "Owns pure authorization predicates for server application commands."

  alias Biot.Protocol.Port
  alias Biot.Server.Actor
  alias Biot.Server.Schema.Biot

  @type grants :: %{shell: boolean(), view_ports: [Port.t()]}
  @type role :: :owner | {:collaborator, grants()}

  @spec owner?(Actor.t() | nil, Biot.t()) :: boolean()
  def owner?(%Actor{principal_id: principal_id}, %Biot{owner_id: principal_id}), do: true
  def owner?(_actor, %Biot{}), do: false

  @spec may_control_lifecycle?(Actor.t() | nil, Biot.t()) :: boolean()
  def may_control_lifecycle?(actor, biot), do: owner?(actor, biot)

  @spec may_change_policy?(Actor.t() | nil, Biot.t()) :: boolean()
  def may_change_policy?(actor, biot), do: owner?(actor, biot)

  @spec may_read_grants?(Actor.t() | nil, Biot.t()) :: boolean()
  def may_read_grants?(actor, biot), do: owner?(actor, biot)

  @spec may_view?(Actor.t() | nil, Biot.t(), Port.t(), [Port.t()]) :: boolean()
  def may_view?(%Actor{} = actor, %Biot{} = biot, %Port{} = port, view_ports) do
    owner?(actor, biot) or port in view_ports
  end

  def may_view?(_actor, %Biot{}, %Port{}, _view_ports), do: false

  @spec role(Actor.t(), Biot.t(), grants()) :: role()
  def role(%Actor{} = actor, %Biot{} = biot, grants) do
    if owner?(actor, biot), do: :owner, else: {:collaborator, grants}
  end
end
