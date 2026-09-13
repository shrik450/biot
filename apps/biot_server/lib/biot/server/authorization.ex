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

  @spec may_read?(Actor.t() | nil, Biot.t(), grants()) :: boolean()
  def may_read?(%Actor{} = actor, %Biot{} = biot, %{shell: shell, view_ports: view_ports})
      when is_boolean(shell) and is_list(view_ports) do
    owner?(actor, biot) or shell or view_ports != []
  end

  def may_read?(_actor, %Biot{}, _grants), do: false

  @spec may_view?(Actor.t() | nil, Biot.t(), Port.t(), [Port.t()]) :: boolean()
  def may_view?(%Actor{} = actor, %Biot{} = biot, %Port{} = port, view_ports) do
    owner?(actor, biot) or port in view_ports
  end

  def may_view?(_actor, %Biot{}, %Port{}, _view_ports), do: false

  @spec may_shell?(Actor.t() | nil, Biot.t(), boolean()) :: boolean()
  def may_shell?(%Actor{} = actor, %Biot{} = biot, shell_granted)
      when is_boolean(shell_granted) do
    owner?(actor, biot) or shell_granted
  end

  def may_shell?(_actor, %Biot{}, _shell_granted), do: false

  @spec role(Actor.t(), Biot.t(), grants()) :: role()
  def role(%Actor{} = actor, %Biot{} = biot, grants) do
    if owner?(actor, biot), do: :owner, else: {:collaborator, grants}
  end
end
