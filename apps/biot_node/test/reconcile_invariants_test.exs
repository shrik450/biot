defmodule Biot.Node.ReconcileInvariantsTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Allocation
  alias Biot.Node.Installation
  alias Biot.Node.NodeState
  alias Biot.Node.Reconcile
  alias Biot.Node.ReconcileGenerators, as: Generators
  alias Biot.Protocol.Failure

  # The three actions a stop or a destruction may cancel, written out here so a change to
  # `Action.metadata/1` has to fail a test rather than move this test's own generator with it.
  @cancellable_actions [:resolve, :prepare, :start]
  @non_cancellable_actions [
    :allocate,
    :initialize,
    :retire,
    :install,
    :release_environment,
    :remove_data,
    :release_allocation
  ]

  describe "totality" do
    property "next/3 always returns one of the five declared shapes" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              current <- Generators.current_action(),
              max_runs: 2000
            ) do
        result = Reconcile.next(spec, state, current)

        assert Generators.valid_result?(result),
               "undeclared result #{inspect(result)}"
      end
    end

    property "every action next/3 returns is one of the ten declared actions" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              max_runs: 1000
            ) do
        assert_valid_action(Reconcile.next(spec, state, nil))
      end
    end

    property "every block reason next/3 returns is one of the three declared reasons" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              current <- Generators.current_action(),
              max_runs: 1000
            ) do
        assert_valid_block_reason(Reconcile.next(spec, state, current))
      end
    end

    property "next/3 never returns a control block" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              current <- Generators.current_action(),
              max_runs: 2000
            ) do
        refute Reconcile.next(spec, state, current) == {:blocked, :control_offline}
      end
    end
  end

  describe "safety invariants" do
    property "(a) initialized data are never cloned again" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              max_runs: 1000
            ) do
        refute match?(
                 {:run, {:initialize, %Allocation{initialization: :complete}, _source}},
                 Reconcile.next(spec, state, nil)
               )
      end
    end

    property "(b) data and the allocation are given back only when the biot is destroyed" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              current <- Generators.current_action(),
              max_runs: 1000
            ) do
        result = Reconcile.next(spec, state, current)

        assert removal?(result) in [false, spec.desired.state == :destroyed]
      end
    end

    property "(c) a container is never started while one is present" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              max_runs: 1000
            ) do
        assert_no_start_while_present(state.container, Reconcile.next(spec, state, nil))
      end
    end

    property "(d) an environment is never installed while a container is present" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              max_runs: 1000
            ) do
        assert_no_install_while_present(
          state.container,
          Reconcile.next(spec, state, nil)
        )
      end
    end

    property "(e) a recorded non-automatic failure for this revision runs nothing" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              failure <- non_automatic_failure(),
              current <- Generators.current_action(),
              max_runs: 1000
            ) do
        blocked = %{state | failure: {spec.desired.revision, failure}}
        result = Reconcile.next(spec, blocked, current)

        refute match?({:run, _action}, result)

        assert result in [:cancel_current, {:blocked, {:recorded_failure, failure}}] or
                 match?({:blocked, {:current_action, _action}}, result)
      end
    end

    property "(f) no action is returned while an input that action needs is unknown" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              max_runs: 2000
            ) do
        result = Reconcile.next(spec, state, nil)

        assert unknown_inputs(result, spec, state) == []
      end
    end

    property "(g) a released environment is neither desired nor installed" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              max_runs: 2000
            ) do
        assert_release_is_unretained(
          Reconcile.next(spec, state, nil),
          spec,
          state
        )
      end
    end

    property "(h) a current action that cannot be cancelled blocks everything else" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              action <- non_cancellable_action(),
              max_runs: 1000
            ) do
        assert Reconcile.next(spec, state, action) ==
                 {:blocked, {:current_action, action}}
      end
    end

    property "a cancellable current action is cancelled only by a stop or a destruction" do
      check all(
              spec <- Generators.execution_spec(),
              state <- Generators.node_state(),
              action <- cancellable_action(),
              max_runs: 1000
            ) do
        assert Reconcile.next(spec, state, action) ==
                 expected_for_cancellable(spec.desired.state, action)
      end
    end
  end

  describe "each action's own required facts" do
    setup do
      %{
        initialized:
          state(
            data: {:present, allocation()},
            resolutions: %{e1() => {:present, resolution(e1())}}
          )
      }
    end

    test "allocate needs known data" do
      failure = inspection(:allocation)

      assert Reconcile.next(spec(), state(data: {:unknown, allocation(), failure}), nil) ==
               {:blocked, {:inspection, failure}}
    end

    test "initialize needs known data" do
      failure = inspection(:data)
      state = state(data: {:unknown, fresh_allocation(), failure})

      assert Reconcile.next(spec(), state, nil) == {:blocked, {:inspection, failure}}
    end

    test "resolve needs a known prepared set", %{initialized: initialized} do
      failure = inspection(:prepared)
      state = %{initialized | resolutions: %{}, prepared: %{e1() => {:unknown, failure}}}

      assert Reconcile.next(spec(), state, nil) == {:blocked, {:inspection, failure}}
    end

    test "prepare needs a known resolution for the desired environment", %{
      initialized: initialized
    } do
      failure = inspection(:resolution)
      state = %{initialized | resolutions: %{e1() => {:unknown, resolution(e1()), failure}}}

      assert Reconcile.next(spec(), state, nil) == {:blocked, {:inspection, failure}}
    end

    test "prepare and install need a known installation", %{initialized: initialized} do
      failure = inspection(:installation)
      state = %{initialized | installation: {:unknown, installation(e1()), failure}}

      assert Reconcile.next(spec(), state, nil) == {:blocked, {:inspection, failure}}
    end

    test "install needs a known container", %{initialized: initialized} do
      failure = inspection(:container)

      state = %{
        initialized
        | prepared: %{e1() => {:present, artifact(e1())}},
          container: {:unknown, failure}
      }

      assert Reconcile.next(spec(), state, nil) == {:blocked, {:inspection, failure}}
    end

    test "start needs a known container", %{initialized: initialized} do
      failure = inspection(:container)

      state = %{
        initialized
        | prepared: %{e1() => {:present, artifact(e1())}},
          installation: {:present, installation(e1())},
          container: {:unknown, failure}
      }

      assert Reconcile.next(spec(), state, nil) == {:blocked, {:inspection, failure}}
    end

    test "start needs a known installation", %{initialized: initialized} do
      failure = inspection(:installation)

      state = %{
        initialized
        | prepared: %{e1() => {:present, artifact(e1())}},
          installation: {:unknown, installation(e1()), failure}
      }

      assert Reconcile.next(spec(), state, nil) == {:blocked, {:inspection, failure}}
    end

    test "retire needs a known container" do
      failure = inspection(:container)
      state = %{settled(e1()) | container: {:unknown, failure}}

      assert Reconcile.next(spec(state: :stopped, revision: 2), state, nil) ==
               {:blocked, {:inspection, failure}}
    end

    test "remove_data and release_allocation need known data" do
      failure = inspection(:data)
      state = state(data: {:unknown, allocation(), failure})

      assert Reconcile.next(spec(state: :destroyed, revision: 3), state, nil) ==
               {:blocked, {:inspection, failure}}
    end

    test "release_environment waits rather than releasing while the container is unknown" do
      stale = %{
        settled(e1())
        | container: {:unknown, inspection(:container)},
          prepared: %{
            e1() => {:present, artifact(e1())},
            e2() => {:present, artifact(e2())}
          }
      }

      # An unknown container could still be using e2, so nothing is given back. Execution reports
      # the same unknown fact first.
      assert Reconcile.next(spec(), stale, nil) ==
               {:blocked, {:inspection, inspection(:container)}}

      assert Reconcile.next(spec(state: :destroyed, revision: 3), stale, nil) ==
               {:blocked, {:inspection, inspection(:container)}}
    end
  end

  defp assert_valid_action({:run, action}) do
    assert Generators.valid_action?(action), "undeclared action #{inspect(action)}"
  end

  defp assert_valid_action(_result), do: assert(true)

  defp assert_valid_block_reason({:blocked, reason}) do
    assert Generators.valid_block_reason?(reason), "undeclared block reason #{inspect(reason)}"
  end

  defp assert_valid_block_reason(_result), do: assert(true)

  defp assert_no_start_while_present({:present, _container}, result) do
    refute match?({:run, {:start, _allocation, _installation}}, result)
  end

  defp assert_no_start_while_present(_container, _result), do: assert(true)

  defp assert_no_install_while_present({:present, _container}, result) do
    refute match?({:run, {:install, _allocation, _artifact, _environment}}, result)
  end

  defp assert_no_install_while_present(_container, _result), do: assert(true)

  defp assert_release_is_unretained({:run, {:release_environment, id}}, spec, state) do
    refute id in retained_by_intent(spec.desired.state, spec.desired.environment_id, state)
  end

  defp assert_release_is_unretained(_result, _spec, _state), do: assert(true)

  # A destroyed biot keeps nothing of its own, so neither its desired nor its installed
  # environment is retained once its container is gone.
  defp retained_by_intent(:destroyed, _environment_id, _state), do: []

  defp retained_by_intent(_desired_state, environment_id, state) do
    [environment_id | installed_environment(state.installation)]
  end

  defp installed_environment({:present, %Installation{environment_id: id}}), do: [id]
  defp installed_environment({:unknown, %Installation{environment_id: id}, _failure}), do: [id]
  defp installed_environment(_installation), do: []

  defp removal?({:run, {:remove_data, _allocation}}), do: true
  defp removal?({:run, {:release_allocation, _allocation}}), do: true
  defp removal?(_result), do: false

  defp unknown_inputs({:run, action}, spec, state) do
    Enum.filter(needed_inputs(action), &unknown?(state, spec, &1))
  end

  defp unknown_inputs(_result, _spec, _state), do: []

  defp needed_inputs({:allocate, _biot_id}), do: [:data]
  defp needed_inputs({:initialize, _allocation, _source}), do: [:data]
  defp needed_inputs({:resolve, _id, _selection, _allocation}), do: [:installation, :prepared]
  defp needed_inputs({:prepare, _id, _manifest}), do: [:installation, :prepared, :resolution]
  defp needed_inputs({:retire, _incarnation}), do: [:container]

  defp needed_inputs({:install, _alloc, _artifact, _id}),
    do: [:installation, :prepared, :container]

  defp needed_inputs({:start, _allocation, _installation}), do: [:installation, :container]
  defp needed_inputs({:release_environment, _id}), do: [:container]
  defp needed_inputs({:remove_data, _allocation}), do: [:data]
  defp needed_inputs({:release_allocation, _allocation}), do: [:data]

  defp unknown?(%NodeState{data: {:unknown, _allocation, _failure}}, _spec, :data), do: true

  defp unknown?(
         %NodeState{installation: {:unknown, _installation, _failure}},
         _spec,
         :installation
       ),
       do: true

  defp unknown?(%NodeState{container: {:unknown, _failure}}, _spec, :container), do: true

  defp unknown?(%NodeState{prepared: prepared}, spec, :prepared) do
    match?({:unknown, _failure}, Map.get(prepared, spec.desired.environment_id))
  end

  defp unknown?(%NodeState{resolutions: resolutions}, spec, :resolution) do
    match?({:unknown, _resolution, _failure}, Map.get(resolutions, spec.desired.environment_id))
  end

  defp unknown?(%NodeState{}, _spec, _input), do: false

  defp expected_for_cancellable(desired_state, _action)
       when desired_state in [:stopped, :destroyed],
       do: :cancel_current

  defp expected_for_cancellable(_desired_state, action), do: {:blocked, {:current_action, action}}

  defp cancellable_action, do: Generators.action(@cancellable_actions)

  defp non_cancellable_action, do: Generators.action(@non_cancellable_actions)

  defp non_automatic_failure do
    StreamData.member_of([
      %Failure{
        stage: :prepare,
        code: :preparation_failed,
        retry: :after_change,
        message: "the environment could not be built",
        diagnostic_ref: nil
      },
      %Failure{
        stage: :initialize,
        code: :lost_data,
        retry: :operator,
        message: "the initialized working data are missing",
        diagnostic_ref: nil
      }
    ])
  end
end
