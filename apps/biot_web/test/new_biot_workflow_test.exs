defmodule BiotWeb.NewBiotWorkflowTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.BiotId
  alias BiotWeb.Live.NewBiotWorkflow
  alias BiotWeb.TestFixtures

  test "allocation advances, waits, or fails for every observation outcome" do
    workflow = workflow(:allocation)

    assert {:deliver_sources, ^workflow} =
             NewBiotWorkflow.advance(workflow, allocation_view(:present))

    assert {:wait, ^workflow} = NewBiotWorkflow.advance(workflow, allocation_view(:unknown))

    assert {:failed, failed} =
             NewBiotWorkflow.advance(workflow, failed_view())

    assert failed.status == :failed
    assert failed.phase == :allocation
    assert failed.reason == :container_failed
    assert failed.runtime_secrets == []
    assert failed.source_credentials == []
  end

  test "preparation advances, waits, or fails for every environment outcome" do
    workflow = workflow(:preparation)
    environment_id = TestFixtures.id(Biot.Protocol.EnvironmentId, 8_001)

    assert {:deliver_runtime_secrets, ^workflow} =
             NewBiotWorkflow.advance(workflow, preparation_view(environment_id))

    assert {:wait, ^workflow} =
             NewBiotWorkflow.advance(workflow, preparation_view(:different_environment))

    assert {:failed, failed} = NewBiotWorkflow.advance(workflow, failed_view())
    assert failed.phase == :preparation
    assert failed.reason == :container_failed
  end

  test "starting chooses start or finish from the final-state decision and fails on reports" do
    running = workflow(:starting, final_state: :running)
    stopped = workflow(:starting, final_state: :stopped)

    assert {:start, ^running} = NewBiotWorkflow.advance(running, healthy_view())
    assert {:finish, ^stopped} = NewBiotWorkflow.advance(stopped, healthy_view())

    assert {:failed, failed} = NewBiotWorkflow.advance(running, failed_view())
    assert failed.phase == :starting
    assert failed.reason == :container_failed
  end

  test "delivery and failure transitions clear pending values and retain the decision" do
    workflow = %NewBiotWorkflow{
      biot_id: TestFixtures.id(BiotId, 8_000),
      phase: :allocation,
      final_state: :stopped,
      runtime_secrets: [%{name: "TOKEN"}],
      source_credentials: [%{source: "https://example.test"}]
    }

    prepared = NewBiotWorkflow.sources_delivered(workflow)
    assert prepared.phase == :preparation
    assert prepared.source_credentials == []
    assert prepared.runtime_secrets == workflow.runtime_secrets

    starting = NewBiotWorkflow.runtime_secrets_delivered(prepared)
    assert starting.phase == :starting
    assert starting.runtime_secrets == []

    failed = NewBiotWorkflow.failed(starting, :starting, :not_ready)
    assert failed.status == :failed
    assert failed.reason == :not_ready
    assert failed.runtime_secrets == []
    assert failed.source_credentials == []
  end

  defp workflow(phase, options \\ []) do
    %NewBiotWorkflow{
      biot_id: TestFixtures.id(BiotId, 8_000),
      phase: phase,
      final_state: Keyword.get(options, :final_state, :running),
      runtime_secrets: [],
      source_credentials: []
    }
  end

  defp allocation_view(data),
    do: %{desired: %{revision: 1}, actual: %{data: data}}

  defp preparation_view(installed_environment),
    do: %{
      desired: %{revision: 1, environment_id: TestFixtures.id(Biot.Protocol.EnvironmentId, 8_001)},
      actual: %{installed_environment: installed_environment}
    }

  defp healthy_view, do: %{desired: %{revision: 1}, actual: %{data: :present}}

  defp failed_view,
    do: %{desired: %{revision: 1}, actual: %{failure: {1, :container_failed}}}
end
