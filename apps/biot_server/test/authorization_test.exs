defmodule Biot.Server.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.Schema.Biot

  @owner_uuid "11111111-1111-4111-8111-111111111111"
  @stranger_uuid "22222222-2222-4222-8222-222222222222"

  setup do
    {:ok, owner_id} = PrincipalId.parse(@owner_uuid)
    {:ok, stranger_id} = PrincipalId.parse(@stranger_uuid)

    %{
      biot: %Biot{owner_id: owner_id},
      owner: %Actor{principal_id: owner_id},
      stranger: %Actor{principal_id: stranger_id}
    }
  end

  test "only the owning principal owns the biot", context do
    assert Authorization.owner?(context.owner, context.biot)
    refute Authorization.owner?(context.stranger, context.biot)
  end

  test "an absent actor owns nothing", context do
    refute Authorization.owner?(nil, context.biot)
  end

  test "only the owner may control the lifecycle", context do
    assert Authorization.may_control_lifecycle?(context.owner, context.biot)
    refute Authorization.may_control_lifecycle?(context.stranger, context.biot)
    refute Authorization.may_control_lifecycle?(nil, context.biot)
  end

  test "only the owner may change policy", context do
    assert Authorization.may_change_policy?(context.owner, context.biot)
    refute Authorization.may_change_policy?(context.stranger, context.biot)
    refute Authorization.may_change_policy?(nil, context.biot)
  end

  test "only the owner may read grants", context do
    assert Authorization.may_read_grants?(context.owner, context.biot)
    refute Authorization.may_read_grants?(context.stranger, context.biot)
    refute Authorization.may_read_grants?(nil, context.biot)
  end

  test "the owner and shell-grant holders may discover publications", context do
    assert Authorization.may_discover?(context.owner, context.biot, [])

    assert Authorization.may_discover?(context.stranger, context.biot, [
             context.stranger.principal_id
           ])

    refute Authorization.may_discover?(context.stranger, context.biot, [])
    refute Authorization.may_discover?(nil, context.biot, [context.stranger.principal_id])
  end
end
