defmodule Biot.Node.Retry do
  @moduledoc """
  The node's failure vocabulary and its retry policy. Every recorded `Failure` is built here, so
  one reason always yields the same code and policy, and the attempt budget stays an argument
  because the controller owns retry configuration and timing.
  """

  alias Biot.Node.Action
  alias Biot.Protocol.Failure

  @reasons ~w(host_unavailable invalid_source resolution_failed build_failed invalid_configuration lost_data ownership_mismatch)a

  @typedoc "The closed set of things that can go wrong with an action, as the node understands them."
  @type reason ::
          :host_unavailable
          | {:container_exited, non_neg_integer()}
          | :invalid_source
          | :resolution_failed
          | :build_failed
          | :invalid_configuration
          | :lost_data
          | :ownership_mismatch

  @typedoc "What the host layer reports back: a classified reason, an error term, or a task exit."
  @type outcome :: reason() | {:error, term()} | {:exit, term()}

  @doc """
  The failure to record for one action's outcome. `attempt` counts this attempt within the current
  desired revision; an automatic retry becomes the operator's problem once the budget is spent.

  The caller fills in `diagnostic_ref` when it has stored a diagnostic for this failure.
  """
  @spec classify(Action.t(), outcome(), pos_integer(), pos_integer()) :: Failure.t()
  def classify(action, outcome, attempt, budget) do
    reason = reason(outcome)
    recorded = failure(reason, Action.stage(action))

    with_budget(%{recorded | message: message(outcome)}, attempt, budget)
  end

  @doc """
  The same failure with the attempt budget applied, for a failure found without an action. An
  automatic retry becomes the operator's problem once the budget is spent.
  """
  @spec with_budget(Failure.t(), pos_integer(), pos_integer()) :: Failure.t()
  def with_budget(%Failure{} = failure, attempt, budget) do
    %{failure | retry: budgeted(failure.retry, attempt, budget)}
  end

  @doc """
  The failure for a reason discovered without running an action, such as data that inspection
  found missing. Budgeted reasons come back `automatic`; `classify/4` applies the budget.
  """
  @spec failure(reason(), Failure.stage()) :: Failure.t()
  def failure(reason, stage) do
    %Failure{
      stage: stage,
      code: code(reason),
      retry: policy(reason),
      message: message(reason),
      diagnostic_ref: nil
    }
  end

  # An unrecognized error term or a dead task is a host problem the node cannot name; retrying it is
  # the only useful answer, and the message keeps the original term for the operator.
  defp reason({:error, _term}), do: :host_unavailable
  defp reason({:exit, _term}), do: :host_unavailable
  defp reason({:container_exited, status}), do: {:container_exited, status}
  defp reason(reason) when reason in @reasons, do: reason

  defp code(:host_unavailable), do: :resource_unavailable
  defp code({:container_exited, _status}), do: :container_failed
  defp code(:invalid_source), do: :invalid_source
  defp code(:resolution_failed), do: :resolution_failed
  defp code(:build_failed), do: :preparation_failed
  defp code(:invalid_configuration), do: :invalid_configuration
  defp code(:lost_data), do: :lost_data
  defp code(:ownership_mismatch), do: :ownership_mismatch

  # Host trouble and a container exit may pass on their own. Bad inputs need a new revision. Lost
  # data and a resource this biot does not own need a person.
  defp policy(:host_unavailable), do: :automatic
  defp policy({:container_exited, _status}), do: :automatic
  defp policy(:invalid_source), do: :after_change
  defp policy(:resolution_failed), do: :after_change
  defp policy(:build_failed), do: :after_change
  defp policy(:invalid_configuration), do: :after_change
  defp policy(:lost_data), do: :operator
  defp policy(:ownership_mismatch), do: :operator

  defp budgeted(:automatic, attempt, budget) when attempt >= budget, do: :operator
  defp budgeted(policy, _attempt, _budget), do: policy

  defp message({:error, term}), do: "the host reported an error: " <> describe(term)
  defp message({:exit, term}), do: "the host task exited: " <> describe(term)
  defp message({:container_exited, status}), do: "the container exited with status #{status}"
  defp message(:host_unavailable), do: "the host could not complete this work"
  defp message(:invalid_source), do: "a selected source could not be used"
  defp message(:resolution_failed), do: "the environment could not be resolved"
  defp message(:build_failed), do: "the environment could not be built"
  defp message(:invalid_configuration), do: "the environment cannot run as configured"
  defp message(:lost_data), do: "the initialized working data are missing"
  defp message(:ownership_mismatch), do: "a host resource is not owned by this biot"

  # A failure is a bounded report, not a log; the diagnostic carries the detail.
  defp describe(term), do: term |> inspect(limit: 8, printable_limit: 240) |> String.slice(0, 240)
end
