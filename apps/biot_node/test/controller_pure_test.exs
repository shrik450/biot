defmodule Biot.Node.ControllerPureTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Backoff
  alias Biot.Node.Host.Inspection
  alias Biot.Node.LocalIntent
  alias Biot.Node.Observation
  alias Biot.Node.Orphans
  alias Biot.Node.Retry
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.Failure

  describe "Observation.node_state/4" do
    test "copies every inspected fact and the controller-owned failure" do
      inspection = host_inspection(container: running(e1()))
      failure = {7, failure(:operator)}

      result = Observation.node_state(inspection, desired(:running), nil, failure)

      assert result.data == inspection.data
      assert result.resolutions == inspection.resolutions
      assert result.installation == inspection.installation
      assert result.container == inspection.container
      assert result.prepared == inspection.prepared
      assert result.failure == failure
    end

    test "the pending exit rule covers every desired state and inspected container state" do
      carried = %{incarnation_id: next_incarnation(), exit_status: 15}
      observed = %{incarnation_id: incarnation(), exit_status: 137}

      containers = [
        {:absent, :absent},
        {:unknown, {:unknown, inspection(:container)}},
        {:running, running(e1())},
        {:exited, exited(e1(), 137)}
      ]

      for desired_state <- [:running, :stopped, :destroyed],
          {container_state, container} <- containers do
        result =
          host_inspection(container: container)
          |> Observation.node_state(desired(desired_state), carried, nil)

        expected =
          case {desired_state, container_state} do
            {:running, :exited} -> observed
            {:running, _other} -> carried
            {_not_running, _container} -> nil
          end

        assert result.pending_exit == expected,
               "desired=#{desired_state} container=#{container_state}"
      end
    end
  end

  describe "Observation.report/2" do
    test "projects every closed data, installation, and container state" do
      installations = [
        {nil, nil},
        {{:present, installation(e1())}, e1()},
        {{:lost, installation(e1())}, nil},
        {{:unknown, installation(e1()), inspection(:installation)}, nil}
      ]

      containers = [
        {:absent, :absent},
        {{:unknown, inspection(:container)}, :unknown},
        {running(e1()), {:present, incarnation(), :running}},
        {exited(e1(), 9), {:present, incarnation(), {:exited, 9}}}
      ]

      data_states = [
        {:no_allocation, :no_allocation},
        {{:unknown, allocation(), inspection(:data)}, :unknown},
        {{:uninitialized, fresh_allocation()}, :uninitialized},
        {{:present, allocation(), marker()}, :present},
        {{:lost, allocation()}, :lost}
      ]

      failure = {8, failure(:after_change)}
      spec = %BiotSpec{execution: spec(revision: 8), access_revision: 13}

      for {installation_state, installed_environment_id} <- installations,
          {container_state, reported_container} <- containers,
          {data_state, reported_data} <- data_states do
        report =
          state(
            installation: installation_state,
            container: container_state,
            data: data_state,
            failure: failure
          )
          |> then(&Observation.report(spec, &1))

        assert report.accepted_revision == 8
        assert report.applied_access_revision == 13
        assert report.installed_environment_id == installed_environment_id
        assert report.container == reported_container
        assert report.data == reported_data
        assert report.failure == failure
      end
    end
  end

  describe "Backoff.delay/3" do
    test "the closed examples double from the minimum and stop at the maximum" do
      assert Enum.map(1..7, &Backoff.delay(&1, 25, 200)) == [25, 50, 100, 200, 200, 200, 200]
      assert Backoff.delay(1, 90, 90) == 90
    end

    property "the delay is monotone and remains within both bounds" do
      check all(
              minimum <- StreamData.integer(1..10_000),
              width <- StreamData.integer(0..100_000),
              attempt <- StreamData.integer(1..30)
            ) do
        maximum = minimum + width
        delay = Backoff.delay(attempt, minimum, maximum)
        next_delay = Backoff.delay(attempt + 1, minimum, maximum)

        assert delay >= minimum
        assert delay <= maximum
        assert next_delay >= delay
        assert next_delay <= maximum
      end
    end
  end

  describe "Orphans.detect/2" do
    test "covers the empty, claimed, orphaned, and mixed sets" do
      first = allocation()

      second = %{
        allocation()
        | biot_id: other_biot_id(),
          uid_range: %{start: 700_000, count: 65_536}
      }

      cases = [
        {[], [], []},
        {[first], [intent(first.biot_id)], []},
        {[first], [], [first]},
        {[first, second], [intent(first.biot_id)], [second]},
        {[first, second], [intent(second.biot_id), intent(first.biot_id)], []}
      ]

      for {allocations, intents, expected} <- cases do
        assert Orphans.detect(allocations, intents) ==
                 Enum.map(
                   expected,
                   &%Biot.Protocol.OrphanedAllocation{
                     biot_id: &1.biot_id,
                     uid_range: &1.uid_range
                   }
                 )
      end
    end
  end

  describe "Retry.with_budget/3" do
    test "exhausts only automatic failures at the budget boundary" do
      for policy <- [:automatic, :after_change, :operator], attempt <- 1..5, budget <- 1..4 do
        expected = if policy == :automatic and attempt >= budget, do: :operator, else: policy
        assert Retry.with_budget(failure(policy), attempt, budget).retry == expected
      end
    end

    test "changes no field except an exhausted automatic policy" do
      failure = failure(:automatic)
      assert Retry.with_budget(failure, 2, 2) == %{failure | retry: :operator}
      assert Retry.with_budget(failure, 1, 2) == failure
    end
  end

  defp host_inspection(overrides) do
    defaults = %Inspection{
      data: {:present, allocation(), marker()},
      resolutions: %{e1() => {:present, resolution(e1())}},
      installation: {:present, installation(e1())},
      container: :absent,
      prepared: {:present, %{e1() => artifact(e1())}}
    }

    struct!(defaults, overrides)
  end

  defp desired(state) do
    %Desired{revision: 8, state: state, environment_id: e1()}
  end

  defp failure(policy) do
    %Failure{
      stage: :start,
      code: :container_failed,
      retry: policy,
      message: "the container exited",
      diagnostic_ref: nil
    }
  end

  defp intent(id) do
    %LocalIntent{
      biot_id: id,
      biot_spec: %BiotSpec{execution: spec(biot_id: id), access_revision: 1}
    }
  end
end
