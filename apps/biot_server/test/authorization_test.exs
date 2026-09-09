defmodule Biot.Server.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.TestFixtures

  @owner_uuid "11111111-1111-4111-8111-111111111111"
  @stranger_uuid "22222222-2222-4222-8222-222222222222"

  setup do
    {:ok, owner_id} = PrincipalId.parse(@owner_uuid)
    {:ok, stranger_id} = PrincipalId.parse(@stranger_uuid)

    %{
      biot: %BiotRow{owner_id: owner_id},
      owner: %Actor{principal_id: owner_id},
      stranger: %Actor{principal_id: stranger_id},
      port: TestFixtures.port(4_000)
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

  test "the owner is the owner whatever grants they hold", context do
    assert Authorization.role(context.owner, context.biot, %{shell: false, view_ports: []}) ==
             :owner

    assert Authorization.role(context.owner, context.biot, %{
             shell: true,
             view_ports: [context.port]
           }) == :owner
  end

  test "anyone else is a collaborator carrying their own grants", context do
    grants = %{shell: true, view_ports: [context.port]}

    assert Authorization.role(context.stranger, context.biot, grants) ==
             {:collaborator, grants}
  end

  test "a collaborator with no grants still reports the empty grants", context do
    empty = %{shell: false, view_ports: []}

    assert Authorization.role(context.stranger, context.biot, empty) ==
             {:collaborator, empty}
  end
end
