defmodule Biot.Server.Operations.Completion do
  @moduledoc "Decides lifecycle operation outcomes from current intent and one report."

  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Failure
  alias Biot.Server.Schema.Operation

  @type result :: :pending | :succeeded | {:failed, Failure.t()}

  @spec decide(Operation.kind(), pos_integer(), Desired.t(), ExecutionReport.t()) :: result()
  def decide(
        _kind,
        target_revision,
        %Desired{},
        %ExecutionReport{failure: {target_revision, failure}}
      ),
      do: {:failed, failure}

  def decide(
        kind,
        target_revision,
        %Desired{revision: target_revision, state: :running} = desired,
        %ExecutionReport{} = report
      )
      when kind in [:create, :update_environment] do
    running_with_environment(desired, report)
  end

  def decide(
        kind,
        target_revision,
        %Desired{
          revision: target_revision,
          state: :stopped,
          environment_id: environment_id
        },
        %ExecutionReport{installed_environment_id: environment_id, container: :absent}
      )
      when kind in [:create, :update_environment],
      do: :succeeded

  def decide(
        :start,
        target_revision,
        %Desired{revision: target_revision} = desired,
        %ExecutionReport{} = report
      ) do
    running_with_environment(desired, report)
  end

  def decide(
        :stop,
        target_revision,
        %Desired{revision: target_revision},
        %ExecutionReport{container: :absent}
      ),
      do: :succeeded

  def decide(
        :destroy,
        target_revision,
        %Desired{revision: target_revision},
        %ExecutionReport{container: :absent, data: :no_allocation}
      ),
      do: :succeeded

  def decide(_kind, _target_revision, %Desired{}, %ExecutionReport{}), do: :pending

  defp running_with_environment(
         %Desired{environment_id: environment_id},
         %ExecutionReport{
           installed_environment_id: environment_id,
           container: {:present, _incarnation_id, :running}
         }
       ),
       do: :succeeded

  defp running_with_environment(%Desired{}, %ExecutionReport{}), do: :pending
end
