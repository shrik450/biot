defmodule Biot.Node.RetryTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Retry
  alias Biot.Protocol.Failure

  # Every outcome the host layer can report, with the code it always yields and the policy it
  # yields before any budget applies.
  @outcomes [
    {"host unavailable", :host_unavailable, :resource_unavailable, :automatic},
    {"container exited", {:container_exited, 137}, :container_failed, :automatic},
    {"credential refused", {:credential_refused, repository()}, :invalid_source, :after_change},
    {"host error term", {:error, :enospc}, :resource_unavailable, :automatic},
    {"host task exit", {:exit, :killed}, :resource_unavailable, :automatic},
    {"invalid source", :invalid_source, :invalid_source, :after_change},
    {"resolution failed", :resolution_failed, :resolution_failed, :after_change},
    {"build failed", :build_failed, :preparation_failed, :after_change},
    {"invalid configuration", :invalid_configuration, :invalid_configuration, :after_change},
    {"lost data", :lost_data, :lost_data, :operator},
    {"ownership mismatch", :ownership_mismatch, :ownership_mismatch, :operator}
  ]

  describe "classify/4 codes and policies" do
    test "every outcome yields its own code, whatever the attempt" do
      for {name, outcome, code, _policy} <- @outcomes, attempt <- 1..4 do
        failure = Retry.classify({:start, allocation(), installation(e1())}, outcome, attempt, 3)

        assert failure.code == code, "#{name} at attempt #{attempt}: wrong code"
      end
    end

    test "an automatic outcome retries below the budget and needs a person at or above it" do
      assert length(automatic_outcomes()) == 4

      for {name, outcome} <- automatic_outcomes() do
        action = {:start, allocation(), installation(e1())}

        assert Retry.classify(action, outcome, 1, 3).retry == :automatic,
               "#{name}: attempt 1 of 3"

        assert Retry.classify(action, outcome, 2, 3).retry == :automatic,
               "#{name}: attempt 2 of 3"

        assert Retry.classify(action, outcome, 3, 3).retry == :operator, "#{name}: attempt 3 of 3"
        assert Retry.classify(action, outcome, 4, 3).retry == :operator, "#{name}: attempt 4 of 3"
      end
    end

    test "a budget of one makes the first automatic failure the operator's problem" do
      for {name, outcome} <- automatic_outcomes() do
        action = {:start, allocation(), installation(e1())}

        assert Retry.classify(action, outcome, 1, 1).retry == :operator, "#{name}: budget of one"
      end
    end

    test "the budget never softens or hardens a non-automatic policy" do
      for {name, outcome, _code, policy} <- @outcomes,
          policy != :automatic,
          attempt <- 1..4,
          budget <- 1..3 do
        action = {:prepare, e1(), manifest(), allocation()}

        assert Retry.classify(action, outcome, attempt, budget).retry == policy,
               "#{name} at attempt #{attempt} of #{budget}"
      end
    end
  end

  describe "classify/4 report fields" do
    test "the stage comes from the action, not from the outcome" do
      actions = [
        {{:allocate, biot_id()}, :allocate},
        {{:initialize, fresh_allocation(), repository()}, :initialize},
        {{:resolve, e1(), selection(), allocation()}, :resolve},
        {{:prepare, e1(), manifest(), allocation()}, :prepare},
        {{:retire, incarnation()}, :retire},
        {{:install, allocation(), artifact(e1()), e1()}, :install},
        {{:start, allocation(), installation(e1())}, :start},
        {{:release_environment, e1(), allocation()}, :release_environment},
        {{:remove_data, allocation()}, :remove_data},
        {{:release_allocation, allocation()}, :release_allocation}
      ]

      for {action, stage} <- actions, {_name, outcome, _code, _policy} <- @outcomes do
        assert Retry.classify(action, outcome, 1, 3).stage == stage
      end
    end

    test "every report carries a message and no diagnostic of its own" do
      for {name, outcome, _code, _policy} <- @outcomes do
        failure = Retry.classify({:prepare, e1(), manifest(), allocation()}, outcome, 1, 3)

        assert failure.message != "", "#{name}: empty message"
        assert failure.diagnostic_ref == nil, "#{name}: unexpected diagnostic"
      end
    end

    test "a container exit names the status the host reported" do
      failure =
        Retry.classify({:start, allocation(), installation(e1())}, {:container_exited, 9}, 1, 3)

      assert failure.message == "the container exited with status 9"
    end

    test "an unnamed host error keeps the original term inside a bounded message" do
      failure =
        Retry.classify({:prepare, e1(), manifest(), allocation()}, {:error, :enospc}, 1, 3)

      assert failure.message == "the host reported an error: :enospc"
    end

    property "a report stays bounded however large the host's term is" do
      check all(term <- StreamData.term()) do
        failure =
          Retry.classify({:prepare, e1(), manifest(), allocation()}, {:error, term}, 1, 3)

        assert String.length(failure.message) <= 300
        assert String.valid?(failure.message)
      end
    end

    property "every classified failure survives the protocol's codec" do
      check all(
              outcome <- StreamData.member_of(Enum.map(@outcomes, &elem(&1, 1))),
              attempt <- StreamData.integer(1..5),
              budget <- StreamData.integer(1..5)
            ) do
        failure =
          Retry.classify({:prepare, e1(), manifest(), allocation()}, outcome, attempt, budget)

        assert Failure.parse(Failure.encode(failure)) == {:ok, failure}
      end
    end
  end

  defp automatic_outcomes do
    for {name, outcome, _code, :automatic} <- @outcomes, do: {name, outcome}
  end

  describe "failure/2" do
    test "the caller names the stage and the reason names the code and the policy" do
      for {name, outcome, code, policy} <- @outcomes,
          not match?({:error, _term}, outcome),
          not match?({:exit, _term}, outcome) do
        failure = Retry.failure(outcome, :inspect)

        assert failure.stage == :inspect, "#{name}: wrong stage"
        assert failure.code == code, "#{name}: wrong code"
        assert failure.retry == policy, "#{name}: wrong policy"
        assert failure.message != "", "#{name}: empty message"
        assert failure.diagnostic_ref == nil, "#{name}: unexpected diagnostic"
      end
    end

    test "an automatic reason comes back automatic, because classify/4 owns the budget" do
      assert Retry.failure(:host_unavailable, :install).retry == :automatic
      assert Retry.failure({:container_exited, 1}, :start).retry == :automatic
    end
  end
end
