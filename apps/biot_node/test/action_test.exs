defmodule Biot.Node.ActionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Action
  alias Biot.Protocol.Failure

  # Every action, with the facts the rest of the node reads about it. Adding an action means
  # adding a row here.
  defp table do
    [
      {"allocate", {:allocate, biot_id()}, :allocate, false},
      {"initialize", {:initialize, fresh_allocation(), repository()}, :initialize, false},
      {"resolve", {:resolve, e1(), selection(), allocation()}, :resolve, true},
      {"prepare", {:prepare, e1(), manifest()}, :prepare, true},
      {"retire", {:retire, incarnation()}, :retire, false},
      {"install", {:install, allocation(), artifact(e1()), e1()}, :install, false},
      {"start", {:start, allocation(), installation(e1())}, :start, true},
      {"release_environment", {:release_environment, e2()}, :release_environment, false},
      {"remove_data", {:remove_data, allocation()}, :remove_data, false},
      {"release_allocation", {:release_allocation, allocation()}, :release_allocation, false}
    ]
  end

  test "every action reports its own stage and cancellation rule" do
    for {name, action, stage, cancellable?} <- table() do
      assert Action.stage(action) == stage, "#{name}: wrong stage"
      assert Action.cancellable?(action) == cancellable?, "#{name}: wrong cancellation"
    end
  end

  test "the protocol knows every stage an action can name" do
    for {name, action, _stage, _cancellable?} <- table() do
      failure = %Failure{
        stage: Action.stage(action),
        code: :resource_unavailable,
        retry: :automatic,
        message: "reported",
        diagnostic_ref: nil
      }

      assert Failure.parse(Failure.encode(failure)) == {:ok, failure}, "#{name}: unknown stage"
    end
  end

  test "giving resources back is never cancelled" do
    for action <- [
          {:retire, incarnation()},
          {:release_environment, e1()},
          {:remove_data, allocation()},
          {:release_allocation, allocation()}
        ] do
      refute Action.cancellable?(action)
    end
  end
end
