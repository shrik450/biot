defmodule Biot.Server.Queries.AccessViewTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.{BiotId, PrincipalId}
  alias Biot.Server.Queries.AccessView
  alias Biot.Server.Queries.AccessView.Input
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.{ShellGrant, ViewGrant}
  alias Biot.Server.TestFixtures

  test "project returns the owner and stable grant ordering" do
    owner_id = TestFixtures.id(PrincipalId, 3)
    first_id = TestFixtures.id(PrincipalId, 1)
    second_id = TestFixtures.id(PrincipalId, 2)
    biot_id = TestFixtures.id(BiotId, 1)
    low_port = TestFixtures.port(3_000)
    high_port = TestFixtures.port(8_080)

    input = %Input{
      biot: %BiotRow{id: biot_id, owner_id: owner_id},
      shell_grants: [
        %ShellGrant{biot_id: biot_id, principal_id: second_id},
        %ShellGrant{biot_id: biot_id, principal_id: first_id}
      ],
      view_grants: [
        %ViewGrant{biot_id: biot_id, port: high_port, principal_id: first_id},
        %ViewGrant{biot_id: biot_id, port: low_port, principal_id: second_id},
        %ViewGrant{biot_id: biot_id, port: low_port, principal_id: first_id}
      ]
    }

    assert AccessView.project(input) == %AccessView{
             owner_id: owner_id,
             shell_grants: [first_id, second_id],
             view_grants: [
               %{port: low_port, principal_id: first_id},
               %{port: low_port, principal_id: second_id},
               %{port: high_port, principal_id: first_id}
             ]
           }
  end

  test "project keeps empty grant lists" do
    input = %Input{
      biot: %BiotRow{owner_id: TestFixtures.id(PrincipalId, 1)},
      shell_grants: [],
      view_grants: []
    }

    assert AccessView.project(input) == %AccessView{
             owner_id: TestFixtures.id(PrincipalId, 1),
             shell_grants: [],
             view_grants: []
           }
  end
end
