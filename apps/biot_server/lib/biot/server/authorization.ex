defmodule Biot.Server.Authorization do
  @moduledoc "Owns pure authorization predicates for server application commands."

  alias Biot.Server.Actor
  alias Biot.Server.Schema.Biot

  @spec owner?(Actor.t() | nil, Biot.t()) :: boolean()
  def owner?(%Actor{principal_id: principal_id}, %Biot{owner_id: principal_id}), do: true
  def owner?(_actor, %Biot{}), do: false

  @spec may_control_lifecycle?(Actor.t() | nil, Biot.t()) :: boolean()
  def may_control_lifecycle?(actor, biot), do: owner?(actor, biot)
end
