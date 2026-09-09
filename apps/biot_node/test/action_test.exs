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
      {"allocate", {:allocate, biot_id()}, :allocate, false, false, []},
      {"initialize", {:initialize, fresh_allocation(), repository()}, :initialize, false, false,
       []},
      {"resolve", {:resolve, e1(), selection(), allocation()}, :resolve, true, true, [e1()]},
      {"prepare", {:prepare, e1(), manifest()}, :prepare, true, true, [e1()]},
      {"retire", {:retire, incarnation()}, :retire, false, false, []},
      {"install", {:install, allocation(), artifact(e1()), e1()}, :install, false, true, [e1()]},
      {"start", {:start, allocation(), installation(e1())}, :start, true, true, [e1()]},
      {"release_environment", {:release_environment, e2()}, :release_environment, false, false,
       [e2()]},
      {"remove_data", {:remove_data, allocation()}, :remove_data, false, false, []},
      {"release_allocation", {:release_allocation, allocation()}, :release_allocation, false,
       false, []}
    ]
  end

  test "every action reports its own stage, cancellation, control need, and environments" do
    for {name, action, stage, cancellable?, requires_control?, environments} <- table() do
      assert Action.stage(action) == stage, "#{name}: wrong stage"
      assert Action.cancellable?(action) == cancellable?, "#{name}: wrong cancellation"
      assert Action.requires_control?(action) == requires_control?, "#{name}: wrong control need"
      assert Action.environments(action) == environments, "#{name}: wrong environments"
    end
  end

  test "the protocol knows every stage an action can name" do
    for {name, action, _stage, _cancellable?, _control?, _environments} <- table() do
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

  test "the four actions that produce state the server must learn about need a control link" do
    needs_control =
      table()
      |> Enum.filter(fn {_name, action, _stage, _c, _r, _e} ->
        Action.requires_control?(action)
      end)
      |> Enum.map(fn {name, _action, _stage, _c, _r, _e} -> name end)

    assert needs_control == ["resolve", "prepare", "install", "start"]
  end

  test "giving resources back is never cancelled and never waits for a control link" do
    for action <- [
          {:retire, incarnation()},
          {:release_environment, e1()},
          {:remove_data, allocation()},
          {:release_allocation, allocation()}
        ] do
      refute Action.cancellable?(action)
      refute Action.requires_control?(action)
    end
  end
end
