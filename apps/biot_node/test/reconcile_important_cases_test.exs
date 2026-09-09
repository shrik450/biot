defmodule Biot.Node.ReconcileImportantCasesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Reconcile
  alias Biot.Protocol.Failure

  describe "important cases (docs/model.md section 4)" do
    test "completed initialization; data absent -> fail lost data" do
      state = state(data: {:lost, allocation()})

      assert Reconcile.next(spec(), state, nil, :ready) ==
               {:failed,
                %Failure{
                  stage: :initialize,
                  code: :lost_data,
                  retry: :operator,
                  message: "the initialized working data are missing",
                  diagnostic_ref: nil
                }}
    end

    test "required inspection unknown -> block and retry; never infer absence" do
      failure = inspection(:data, :timed_out)
      state = state(data: {:unknown, allocation(), failure})

      assert Reconcile.next(spec(), state, nil, :ready) == {:blocked, {:inspection, failure}}
    end

    test "environment unresolved -> resolve once into its atomic node location" do
      state = state(data: {:present, allocation(), marker()})

      assert Reconcile.next(spec(), state, nil, :ready) ==
               {:run, {:resolve, e1(), selection(), allocation()}}
    end

    test "build fails with old container running -> report failure and preserve old execution" do
      recorded = %Failure{
        stage: :prepare,
        code: :preparation_failed,
        retry: :after_change,
        message: "the environment could not be built",
        diagnostic_ref: nil
      }

      state = %{
        settled(e1())
        | resolutions: %{
            e1() => {:present, resolution(e1())},
            e2() => {:present, resolution(e2())}
          },
          failure: {2, recorded}
      }

      # The old container and its installation stay exactly as they were: the only result is the
      # report the controller already holds.
      assert Reconcile.next(spec(environment_id: e2(), revision: 2), state, nil, :ready) ==
               {:blocked, {:recorded_failure, recorded}}
    end

    test "desired environment differs from installation -> prepare, retire, inspect absence, install" do
      state = %{
        settled(e1())
        | resolutions: %{
            e1() => {:present, resolution(e1())},
            e2() => {:present, resolution(e2())}
          }
      }

      assert Reconcile.next(spec(environment_id: e2(), revision: 2), state, nil, :ready) ==
               {:run, {:prepare, e2(), manifest()}}
    end

    test "desired stopped -> retire execution" do
      assert Reconcile.next(spec(state: :stopped, revision: 2), settled(e1()), nil, :ready) ==
               {:run, {:retire, incarnation()}}
    end

    test "desired stopped -> preparation may finish without starting" do
      prepared_but_stopped =
        state(
          data: {:present, allocation(), marker()},
          resolutions: %{e1() => {:present, resolution(e1())}},
          prepared: {:present, %{e1() => artifact(e1())}}
        )

      assert Reconcile.next(spec(state: :stopped, revision: 2), prepared_but_stopped, nil, :ready) ==
               :settled
    end

    test "desired destroyed -> cancel current task" do
      assert Reconcile.next(
               spec(state: :destroyed, revision: 3),
               settled(e1()),
               {:prepare, e1(), manifest()},
               :ready
             ) == :cancel_current
    end

    test "desired destroyed -> retire, remove data, release allocation" do
      assert Reconcile.next(spec(state: :destroyed, revision: 3), settled(e1()), nil, :ready) ==
               {:run, {:retire, incarnation()}}

      released = %{settled(e1()) | container: :absent, prepared: :absent, resolutions: %{}}

      assert Reconcile.next(spec(state: :destroyed, revision: 3), released, nil, :ready) ==
               {:run, {:remove_data, allocation()}}

      removed = %{released | data: {:uninitialized, fresh_allocation()}, installation: nil}

      assert Reconcile.next(spec(state: :destroyed, revision: 3), removed, nil, :ready) ==
               {:run, {:release_allocation, fresh_allocation()}}
    end

    test "control offline -> do not install or start" do
      installable =
        state(
          data: {:present, allocation(), marker()},
          resolutions: %{e1() => {:present, resolution(e1())}},
          prepared: {:present, %{e1() => artifact(e1())}}
        )

      assert Reconcile.next(spec(), installable, nil, :ready) ==
               {:run, {:install, allocation(), artifact(e1()), e1()}}

      assert Reconcile.next(spec(), installable, nil, :offline) == {:blocked, :control_offline}

      startable = %{installable | installation: {:present, installation(e1())}}

      assert Reconcile.next(spec(), startable, nil, :ready) ==
               {:run, {:start, allocation(), installation(e1())}}

      assert Reconcile.next(spec(), startable, nil, :offline) == {:blocked, :control_offline}
    end

    test "control offline -> finish an already accepted stop and destruction" do
      assert Reconcile.next(spec(state: :stopped, revision: 2), settled(e1()), nil, :offline) ==
               {:run, {:retire, incarnation()}}

      released = %{settled(e1()) | container: :absent, prepared: :absent, resolutions: %{}}

      assert Reconcile.next(spec(state: :destroyed, revision: 3), released, nil, :offline) ==
               {:run, {:remove_data, allocation()}}
    end

    test "control offline -> an unallocated biot still allocates and initializes" do
      # The gate covers only the four actions that produce state the server must learn about, so
      # establishing owned data does not wait for a link.
      assert Reconcile.next(spec(), state(), nil, :offline) == {:run, {:allocate, biot_id()}}

      allocated = state(data: {:uninitialized, fresh_allocation()})

      assert Reconcile.next(spec(), allocated, nil, :offline) ==
               {:run, {:initialize, fresh_allocation(), repository()}}
    end

    test "control offline -> inspection still blocks" do
      failure = inspection(:container)
      state = %{settled(e1()) | container: {:unknown, failure}}

      assert Reconcile.next(spec(), state, nil, :offline) == {:blocked, {:inspection, failure}}
    end

    test "desired running; container exited -> retire it" do
      state = %{settled(e1()) | container: exited(e1(), 137)}

      assert Reconcile.next(spec(), state, nil, :ready) == {:run, {:retire, incarnation()}}
    end

    test "desired running; container exited -> after absence, an automatic-retry failure" do
      state = %{
        settled(e1())
        | container: :absent,
          pending_exit: %{incarnation_id: incarnation(), exit_status: 137}
      }

      assert Reconcile.next(spec(), state, nil, :ready) ==
               {:failed,
                %Failure{
                  stage: :start,
                  code: :container_failed,
                  retry: :automatic,
                  message: "the container exited with status 137",
                  diagnostic_ref: nil
                }}
    end

    test "current revision has a recorded after-change failure -> remain blocked" do
      recorded = %Failure{
        stage: :resolve,
        code: :resolution_failed,
        retry: :after_change,
        message: "the environment could not be resolved",
        diagnostic_ref: nil
      }

      state = %{state(data: {:present, allocation(), marker()}) | failure: {1, recorded}}

      assert Reconcile.next(spec(), state, nil, :ready) ==
               {:blocked, {:recorded_failure, recorded}}
    end

    test "current revision has a recorded operator failure -> remain blocked" do
      recorded = %Failure{
        stage: :retire,
        code: :ownership_mismatch,
        retry: :operator,
        message: "a host resource is not owned by this biot",
        diagnostic_ref: nil
      }

      state = %{state(data: {:present, allocation(), marker()}) | failure: {1, recorded}}

      assert Reconcile.next(spec(), state, nil, :ready) ==
               {:blocked, {:recorded_failure, recorded}}
    end

    test "a recorded failure for an older revision says nothing about this one" do
      recorded = %Failure{
        stage: :resolve,
        code: :resolution_failed,
        retry: :after_change,
        message: "the environment could not be resolved",
        diagnostic_ref: nil
      }

      state = %{state(data: {:present, allocation(), marker()}) | failure: {1, recorded}}

      assert Reconcile.next(spec(revision: 2), state, nil, :ready) ==
               {:run, {:resolve, e1(), selection(), allocation()}}
    end

    test "a recorded automatic failure for this revision reconciles again" do
      recorded = %Failure{
        stage: :start,
        code: :container_failed,
        retry: :automatic,
        message: "the container exited with status 137",
        diagnostic_ref: nil
      }

      # The controller owns backoff, so a recorded automatic failure means its delay has elapsed.
      state = %{settled(e1()) | container: :absent, failure: {1, recorded}}

      assert Reconcile.next(spec(), state, nil, :ready) ==
               {:run, {:start, allocation(), installation(e1())}}
    end
  end

  describe "resolution states" do
    test "a lost resolution snapshot is resolved again, never prepared from" do
      state =
        state(
          data: {:present, allocation(), marker()},
          resolutions: %{e1() => {:lost, resolution(e1())}}
        )

      assert Reconcile.next(spec(), state, nil, :ready) ==
               {:run, {:resolve, e1(), selection(), allocation()}}
    end

    test "a resolution for another environment does not resolve the desired one" do
      state =
        state(
          data: {:present, allocation(), marker()},
          resolutions: %{e2() => {:present, resolution(e2())}}
        )

      assert Reconcile.next(spec(), state, nil, :ready) ==
               {:run, {:resolve, e1(), selection(), allocation()}}
    end

    test "a stopped biot resolves and prepares nothing new" do
      state = state(data: {:present, allocation(), marker()})

      assert Reconcile.next(spec(state: :stopped, revision: 2), state, nil, :ready) == :settled
    end

    test "a destroyed biot resolves and prepares nothing new" do
      state = state(data: {:present, allocation(), marker()})

      assert Reconcile.next(spec(state: :destroyed, revision: 3), state, nil, :ready) ==
               {:run, {:remove_data, allocation()}}
    end
  end

  describe "ownership" do
    test "a container another biot owns fails rather than being retired" do
      state = %{settled(e1()) | container: foreign(e1())}

      expected =
        {:failed,
         %Failure{
           stage: :retire,
           code: :ownership_mismatch,
           retry: :operator,
           message: "a host resource is not owned by this biot",
           diagnostic_ref: nil
         }}

      assert Reconcile.next(spec(), state, nil, :ready) == expected
      assert Reconcile.next(spec(state: :stopped, revision: 2), state, nil, :ready) == expected
      assert Reconcile.next(spec(state: :destroyed, revision: 3), state, nil, :ready) == expected
    end
  end

  describe "a lost installation under a running container" do
    test "prepares, retires, installs after absence, then starts" do
      lost = %{settled(e1()) | installation: {:lost, installation(e1())}, prepared: :absent}

      assert Reconcile.next(spec(), lost, nil, :ready) == {:run, {:prepare, e1(), manifest()}}

      prepared_again = %{lost | prepared: {:present, %{e1() => artifact(e1())}}}

      assert Reconcile.next(spec(), prepared_again, nil, :ready) ==
               {:run, {:retire, incarnation()}}

      absent = %{prepared_again | container: :absent}

      assert Reconcile.next(spec(), absent, nil, :ready) ==
               {:run, {:install, allocation(), artifact(e1()), e1()}}

      installed = %{absent | installation: {:present, installation(e1())}}

      assert Reconcile.next(spec(), installed, nil, :ready) ==
               {:run, {:start, allocation(), installation(e1())}}
    end
  end
end
