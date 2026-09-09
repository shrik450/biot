defmodule Biot.Server.Queries.BiotViewTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.OperationId
  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Queries.BiotView
  alias Biot.Server.Queries.BiotView.Input
  alias Biot.Server.Queries.OperationView
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Node
  alias Biot.Server.Schema.Observation
  alias Biot.Server.Schema.Operation

  @biot_uuid "10000000-0000-4000-8000-000000000001"
  @owner_uuid "20000000-0000-4000-8000-000000000002"
  @node_uuid "30000000-0000-4000-8000-000000000003"
  @environment_uuid "40000000-0000-4000-8000-000000000004"
  @operation_uuid "50000000-0000-4000-8000-000000000005"
  @live_connection_uuid "60000000-0000-4000-8000-000000000006"
  @old_connection_uuid "70000000-0000-4000-8000-000000000007"

  setup_all do
    {:ok, biot_id} = BiotId.parse(@biot_uuid)
    {:ok, owner_id} = PrincipalId.parse(@owner_uuid)
    {:ok, node_id} = NodeId.parse(@node_uuid)
    {:ok, environment_id} = EnvironmentId.parse(@environment_uuid)
    {:ok, operation_id} = OperationId.parse(@operation_uuid)
    {:ok, live_connection} = ConnectionId.parse(@live_connection_uuid)
    {:ok, old_connection} = ConnectionId.parse(@old_connection_uuid)

    biot = %BiotRow{
      id: biot_id,
      name: "worker",
      owner_id: owner_id,
      node_id: node_id,
      desired_revision: 3,
      desired_state: :running,
      desired_environment_id: environment_id,
      access_revision: 2
    }

    %{
      biot: biot,
      node: %Node{id: node_id, status: :enabled},
      node_id: node_id,
      environment_id: environment_id,
      operation_id: operation_id,
      live_connection: live_connection,
      old_connection: old_connection
    }
  end

  test "the projection copies durable identity and intent", context do
    view = BiotView.project(input(context, %{}))

    assert view.id == context.biot.id
    assert view.name == "worker"
    assert view.owner_id == context.biot.owner_id
    assert view.node_id == context.node_id

    assert view.desired == %Desired{
             revision: 3,
             state: :running,
             environment_id: context.environment_id
           }

    assert view.publications == []
    assert view.direct_secrets_ever_delivered == false
  end

  test "a biot with no observation has never reported", context do
    view = BiotView.project(input(context, %{observation: nil}))

    assert view.actual == :never_reported
  end

  test "an observation is current only on the node's current connection", context do
    cases = [
      {context.live_connection, %{connection_id: context.live_connection, state: :ready},
       :current},
      {context.old_connection, %{connection_id: context.live_connection, state: :ready}, :stale},
      {context.live_connection, %{connection_id: context.live_connection, state: :synchronizing},
       :current},
      {context.live_connection, nil, :stale}
    ]

    for {observed_connection, connection, expected} <- cases do
      view =
        BiotView.project(
          input(context, %{
            observation: observation(context, %{connection_id: observed_connection}),
            connection: connection
          })
        )

      assert view.actual.freshness == expected,
             "observed #{inspect(observed_connection)} against #{inspect(connection)}"
    end
  end

  test "the reported facts appear unchanged in the view", context do
    observed = observation(context, %{container: :absent, data: :lost})
    view = BiotView.project(input(context, %{observation: observed}))

    assert view.actual.received_at == observed.received_at
    assert view.actual.installed_environment == observed.installed_environment_id
    assert view.actual.container == :absent
    assert view.actual.data == :lost
    assert view.actual.failure == nil
  end

  test "node status combines the operator status with the live connection", context do
    cases = [
      {:enabled, %{connection_id: context.live_connection, state: :ready}, :ready},
      {:enabled, %{connection_id: context.live_connection, state: :synchronizing}, :connecting},
      {:enabled, nil, :unavailable},
      {:disabled, nil, :disabled},
      {:disabled, %{connection_id: context.live_connection, state: :ready}, :disabled},
      {:retired, nil, :retired},
      {:retired, %{connection_id: context.live_connection, state: :ready}, :retired}
    ]

    for {status, connection, expected} <- cases do
      view =
        BiotView.project(
          input(context, %{
            node: %Node{id: context.node_id, status: status},
            connection: connection
          })
        )

      assert view.node == expected, "#{inspect(status)} with #{inspect(connection)}"
    end
  end

  test "the operation is projected when one is given", context do
    operation = %Operation{
      id: context.operation_id,
      kind: :start,
      target_revision: 3,
      outcome: :pending,
      failure: nil
    }

    view = BiotView.project(input(context, %{operation: operation}))

    assert view.operation == OperationView.project(operation)
    assert BiotView.project(input(context, %{operation: nil})).operation == nil
  end

  test "access is applied only when a current report has caught up", context do
    cases = [
      {2, context.live_connection, :applied},
      {3, context.live_connection, :applied},
      {1, context.live_connection, :pending},
      {2, context.old_connection, :pending}
    ]

    for {applied_access_revision, observed_connection, expected} <- cases do
      view =
        BiotView.project(
          input(context, %{
            observation:
              observation(context, %{
                connection_id: observed_connection,
                applied_access_revision: applied_access_revision
              })
          })
        )

      assert view.access.revision == 2

      case expected do
        :applied -> assert view.access.enforcement == :applied
        :pending -> assert view.access.enforcement == {:pending, context.node_id}
      end
    end
  end

  test "a biot that never reported has pending access enforcement", context do
    view = BiotView.project(input(context, %{observation: nil}))

    assert view.access == %{revision: 2, enforcement: {:pending, context.node_id}}
  end

  defp input(context, overrides) do
    defaults = %{
      biot: context.biot,
      observation: observation(context, %{}),
      node: context.node,
      operation: nil,
      connection: %{connection_id: context.live_connection, state: :ready},
      publications: [],
      direct_secrets_ever_delivered: false
    }

    struct!(Input, Map.merge(defaults, overrides))
  end

  defp observation(context, overrides) do
    defaults = %{
      biot_id: context.biot.id,
      connection_id: context.live_connection,
      received_at: ~U[2026-09-08 12:00:00.000000Z],
      accepted_revision: 3,
      installed_environment_id: context.environment_id,
      container: :unknown,
      data: :present,
      failure: nil,
      applied_access_revision: 2
    }

    struct!(Observation, Map.merge(defaults, overrides))
  end
end
