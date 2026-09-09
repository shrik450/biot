defmodule Biot.Server.Operations.CompletionTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Failure
  alias Biot.Protocol.IncarnationId
  alias Biot.Server.Operations.Completion

  @kinds [:create, :start, :stop, :update_environment, :destroy]
  @target_revision 4

  @desired_environment "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @other_environment "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @incarnation "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

  setup_all do
    {:ok, desired_environment} = EnvironmentId.parse(@desired_environment)
    {:ok, other_environment} = EnvironmentId.parse(@other_environment)
    {:ok, incarnation} = IncarnationId.parse(@incarnation)

    failure = %Failure{
      stage: :install,
      code: :installation_failed,
      retry: :after_change,
      message: "nix build failed",
      diagnostic_ref: nil
    }

    %{
      desired_environment: desired_environment,
      other_environment: other_environment,
      incarnation: incarnation,
      failure: failure
    }
  end

  test "the model's completion evidence table decides every kind and report", context do
    for kind <- @kinds,
        desired <- desired_values(context),
        report <- reports(context) do
      expected = expected_outcome(kind, desired, report, context.failure)
      actual = Completion.decide(kind, @target_revision, desired, report)

      assert actual == expected,
             """
             kind: #{inspect(kind)}
             desired: #{inspect(desired)}
             report: #{inspect(report)}
             expected: #{inspect(expected)}
             actual: #{inspect(actual)}
             """
    end
  end

  test "a report older than current intent cannot complete an operation", context do
    complete = %{
      installed_environment_id: context.desired_environment,
      container: {:present, context.incarnation, :running},
      data: :no_allocation
    }

    for kind <- @kinds do
      superseded_desired = %Desired{
        revision: @target_revision + 1,
        state: :running,
        environment_id: context.desired_environment
      }

      report = report(complete)

      assert Completion.decide(kind, @target_revision, superseded_desired, report) == :pending
    end
  end

  test "a failure tagged with this revision fails the operation at any intent", context do
    report = report(%{failure: {@target_revision, context.failure}})

    for kind <- @kinds, revision <- [@target_revision, @target_revision + 3] do
      desired = %Desired{
        revision: revision,
        state: :running,
        environment_id: context.desired_environment
      }

      assert Completion.decide(kind, @target_revision, desired, report) ==
               {:failed, context.failure}
    end
  end

  test "a failure tagged with another revision leaves this operation pending", context do
    report = report(%{failure: {@target_revision - 1, context.failure}})

    desired = %Desired{
      revision: @target_revision,
      state: :running,
      environment_id: context.desired_environment
    }

    for kind <- @kinds do
      refute match?(
               {:failed, _failure},
               Completion.decide(kind, @target_revision, desired, report)
             )
    end
  end

  test "create and update_environment share one rule for each desired state", context do
    installed_and_running = %{
      installed_environment_id: context.desired_environment,
      container: {:present, context.incarnation, :running}
    }

    installed_and_absent = %{
      installed_environment_id: context.desired_environment,
      container: :absent
    }

    for kind <- [:create, :update_environment] do
      assert Completion.decide(
               kind,
               @target_revision,
               desired(:running, context.desired_environment),
               report(installed_and_running)
             ) == :succeeded

      assert Completion.decide(
               kind,
               @target_revision,
               desired(:running, context.desired_environment),
               report(installed_and_absent)
             ) == :pending

      assert Completion.decide(
               kind,
               @target_revision,
               desired(:stopped, context.desired_environment),
               report(installed_and_absent)
             ) == :succeeded

      assert Completion.decide(
               kind,
               @target_revision,
               desired(:stopped, context.desired_environment),
               report(installed_and_running)
             ) == :pending
    end
  end

  test "a stopped create waits for the desired environment, not any environment", context do
    report =
      report(%{installed_environment_id: context.other_environment, container: :absent})

    assert Completion.decide(
             :create,
             @target_revision,
             desired(:stopped, context.desired_environment),
             report
           ) == :pending
  end

  defp desired(state, environment_id) do
    %Desired{revision: @target_revision, state: state, environment_id: environment_id}
  end

  defp desired_values(context) do
    for state <- Desired.states(),
        environment_id <- [context.desired_environment, context.other_environment] do
      %Desired{revision: @target_revision, state: state, environment_id: environment_id}
    end
  end

  defp reports(context) do
    containers = [
      :unknown,
      :absent,
      {:present, context.incarnation, :running},
      {:present, context.incarnation, {:exited, 1}}
    ]

    for installed <- [nil, context.desired_environment, context.other_environment],
        container <- containers,
        data <- ExecutionReport.data_states(),
        failure <- [nil, {@target_revision, context.failure}] do
      report(%{
        installed_environment_id: installed,
        container: container,
        data: data,
        failure: failure
      })
    end
  end

  defp report(fields) do
    %ExecutionReport{
      accepted_revision: Map.get(fields, :accepted_revision, @target_revision),
      installed_environment_id: Map.get(fields, :installed_environment_id),
      container: Map.get(fields, :container, :unknown),
      data: Map.get(fields, :data, :unknown),
      failure: Map.get(fields, :failure),
      applied_access_revision: Map.get(fields, :applied_access_revision, 1)
    }
  end

  # The model's table, written independently of the code under test.
  defp expected_outcome(kind, desired, report, failure) do
    cond do
      report.failure == {@target_revision, failure} -> {:failed, failure}
      desired.revision != @target_revision -> :pending
      true -> evidence(kind, desired, report)
    end
  end

  defp evidence(:start, desired, report) do
    if running_desired_environment?(desired, report), do: :succeeded, else: :pending
  end

  defp evidence(kind, %Desired{state: :running} = desired, report)
       when kind in [:create, :update_environment] do
    if running_desired_environment?(desired, report), do: :succeeded, else: :pending
  end

  defp evidence(kind, %Desired{state: :stopped} = desired, report)
       when kind in [:create, :update_environment] do
    if report.installed_environment_id == desired.environment_id and report.container == :absent,
      do: :succeeded,
      else: :pending
  end

  defp evidence(kind, %Desired{state: :destroyed}, _report)
       when kind in [:create, :update_environment],
       do: :pending

  defp evidence(:stop, _desired, report) do
    if report.container == :absent, do: :succeeded, else: :pending
  end

  defp evidence(:destroy, _desired, report) do
    if report.container == :absent and report.data == :no_allocation,
      do: :succeeded,
      else: :pending
  end

  defp running_desired_environment?(desired, report) do
    report.installed_environment_id == desired.environment_id and
      match?({:present, _incarnation, :running}, report.container)
  end
end
