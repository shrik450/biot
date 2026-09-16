defmodule Biot.Node.ReconcileImportantCasesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Reconcile
  alias Biot.Protocol.Failure

  describe "important cases (docs/model.md section 4)" do
    test "completed initialization; data absent -> fail lost data" do
      state = state(data: {:lost, allocation()})

      assert Reconcile.next(spec(), state, nil) ==
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

      assert Reconcile.next(spec(), state, nil) == {:blocked, {:inspection, failure}}
    end

    test "environment unresolved -> resolve once into its atomic node location" do
      state = state(data: {:present, allocation()})

      assert Reconcile.next(spec(), state, nil) ==
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
      assert Reconcile.next(spec(environment_id: e2(), revision: 2), state, nil) ==
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

      assert Reconcile.next(spec(environment_id: e2(), revision: 2), state, nil) ==
               {:run, {:prepare, e2(), manifest(), allocation()}}
    end

    test "an unknown sibling does not block installing and starting the desired environment" do
      sibling_failure = inspection(:prepared)

      installable =
        state(
          data: {:present, allocation()},
          resolutions: %{
            e1() => {:present, resolution(e1())},
            e2() => {:present, resolution(e2())}
          },
          prepared: %{
            e1() => {:present, artifact(e1())},
            e2() => {:unknown, sibling_failure}
          }
        )

      assert Reconcile.next(spec(), installable, nil) ==
               {:run, {:install, allocation(), artifact(e1()), e1()}}

      startable = %{installable | installation: {:present, installation(e1())}}

      assert Reconcile.next(spec(), startable, nil) ==
               {:run, {:start, allocation(), installation(e1())}}
    end

    test "an unknown desired artifact blocks only work that needs that artifact" do
      failure = inspection(:prepared)

      blocked =
        state(
          data: {:present, allocation()},
          resolutions: %{e1() => {:present, resolution(e1())}},
          prepared: %{e1() => {:unknown, failure}}
        )

      assert Reconcile.next(spec(), blocked, nil) == {:blocked, {:inspection, failure}}

      running = %{
        settled(e1())
        | prepared: %{
            e1() => {:unknown, failure},
            e2() => {:present, artifact(e2())}
          }
      }

      assert Reconcile.next(spec(), running, nil) ==
               {:run, {:release_environment, e2(), allocation()}}

      stopped = %{running | container: :absent, prepared: %{e1() => {:unknown, failure}}}
      assert Reconcile.next(spec(state: :stopped), stopped, nil) == :settled
    end

    test "desired stopped -> retire execution" do
      assert Reconcile.next(spec(state: :stopped, revision: 2), settled(e1()), nil) ==
               {:run, {:retire, incarnation()}}
    end

    test "desired stopped -> retires execution before resolving or preparing" do
      unresolved = %{settled(e1()) | resolutions: %{}, prepared: %{}}

      assert Reconcile.next(spec(state: :stopped, revision: 2), unresolved, nil) ==
               {:run, {:retire, incarnation()}}
    end

    test "desired stopped -> retires execution even when data inspection failed" do
      state = %{settled(e1()) | data: {:unknown, allocation(), inspection(:data)}}

      assert Reconcile.next(spec(state: :stopped, revision: 2), state, nil) ==
               {:run, {:retire, incarnation()}}
    end

    test "desired stopped -> an unknown container blocks before any environment work" do
      state = %{settled(e1()) | container: {:unknown, inspection(:container)}}

      assert Reconcile.next(spec(state: :stopped, revision: 2), state, nil) ==
               {:blocked, {:inspection, inspection(:container)}}
    end

    test "desired stopped -> preparation finishes by installing, without starting" do
      resolved =
        state(
          data: {:present, allocation()},
          resolutions: %{e1() => {:present, resolution(e1())}}
        )

      assert Reconcile.next(spec(state: :stopped, revision: 2), resolved, nil) ==
               {:run, {:prepare, e1(), manifest(), allocation()}}

      prepared = %{resolved | prepared: %{e1() => {:present, artifact(e1())}}}

      assert Reconcile.next(spec(state: :stopped, revision: 2), prepared, nil) ==
               {:run, {:install, allocation(), artifact(e1()), e1()}}

      installed = %{prepared | installation: {:present, installation(e1())}}
      assert Reconcile.next(spec(state: :stopped, revision: 2), installed, nil) == :settled
    end

    test "desired stopped -> an installed environment is never started" do
      installed = %{settled(e1()) | container: :absent}

      assert Reconcile.next(spec(state: :stopped, revision: 2), installed, nil) == :settled

      # The same facts under running intent are exactly when a start is correct.
      assert Reconcile.next(spec(), installed, nil) ==
               {:run, {:start, allocation(), installation(e1())}}
    end

    test "desired stopped -> an unknown installation blocks instead of starting" do
      failure = inspection(:installation)

      state = %{
        settled(e1())
        | container: :absent,
          installation: {:unknown, installation(e1()), failure}
      }

      assert Reconcile.next(spec(state: :stopped, revision: 2), state, nil) ==
               {:blocked, {:inspection, failure}}
    end

    test "desired destroyed -> cancel current task" do
      assert Reconcile.next(
               spec(state: :destroyed, revision: 3),
               settled(e1()),
               {:prepare, e1(), manifest(), allocation()}
             ) == :cancel_current
    end

    test "desired destroyed -> retire, remove data, release allocation" do
      assert Reconcile.next(spec(state: :destroyed, revision: 3), settled(e1()), nil) ==
               {:run, {:retire, incarnation()}}

      released = %{settled(e1()) | container: :absent, prepared: %{}, resolutions: %{}}

      assert Reconcile.next(spec(state: :destroyed, revision: 3), released, nil) ==
               {:run, {:remove_data, allocation()}}

      removed = %{released | data: {:uninitialized, fresh_allocation()}, installation: nil}

      assert Reconcile.next(spec(state: :destroyed, revision: 3), removed, nil) ==
               {:run, {:release_allocation, fresh_allocation()}}
    end

    test "desired running; container exited -> retire it" do
      state = %{settled(e1()) | container: exited(e1(), 137)}

      assert Reconcile.next(spec(), state, nil) == {:run, {:retire, incarnation()}}
    end

    test "desired running; container exited -> after absence, an automatic-retry failure" do
      state = %{
        settled(e1())
        | container: :absent,
          pending_exit: %{incarnation_id: incarnation(), exit_status: 137}
      }

      assert Reconcile.next(spec(), state, nil) ==
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

      state = %{state(data: {:present, allocation()}) | failure: {1, recorded}}

      assert Reconcile.next(spec(), state, nil) ==
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

      state = %{state(data: {:present, allocation()}) | failure: {1, recorded}}

      assert Reconcile.next(spec(), state, nil) ==
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

      state = %{state(data: {:present, allocation()}) | failure: {1, recorded}}

      assert Reconcile.next(spec(revision: 2), state, nil) ==
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

      assert Reconcile.next(spec(), state, nil) ==
               {:run, {:start, allocation(), installation(e1())}}
    end
  end

  describe "resolution states" do
    test "a lost resolution snapshot is resolved again, never prepared from" do
      state =
        state(
          data: {:present, allocation()},
          resolutions: %{e1() => {:lost, resolution(e1())}}
        )

      assert Reconcile.next(spec(), state, nil) ==
               {:run, {:resolve, e1(), selection(), allocation()}}
    end

    test "a resolution for another environment does not resolve the desired one" do
      state =
        state(
          data: {:present, allocation()},
          resolutions: %{e2() => {:present, resolution(e2())}}
        )

      assert Reconcile.next(spec(), state, nil) ==
               {:run, {:resolve, e1(), selection(), allocation()}}
    end

    test "a stopped biot with no resolution resolves the desired environment" do
      state = state(data: {:present, allocation()})

      assert Reconcile.next(spec(state: :stopped, revision: 2), state, nil) ==
               {:run, {:resolve, e1(), selection(), allocation()}}
    end

    test "a destroyed biot resolves and prepares nothing new" do
      state = state(data: {:present, allocation()})

      assert Reconcile.next(spec(state: :destroyed, revision: 3), state, nil) ==
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

      assert Reconcile.next(spec(), state, nil) == expected
      assert Reconcile.next(spec(state: :stopped, revision: 2), state, nil) == expected
      assert Reconcile.next(spec(state: :destroyed, revision: 3), state, nil) == expected
    end
  end

  describe "a lost installation under a running container" do
    test "prepares, retires, installs after absence, then starts" do
      lost = %{settled(e1()) | installation: {:lost, installation(e1())}, prepared: %{}}

      assert Reconcile.next(spec(), lost, nil) ==
               {:run, {:prepare, e1(), manifest(), allocation()}}

      prepared_again = %{lost | prepared: %{e1() => {:present, artifact(e1())}}}

      assert Reconcile.next(spec(), prepared_again, nil) ==
               {:run, {:retire, incarnation()}}

      absent = %{prepared_again | container: :absent}

      assert Reconcile.next(spec(), absent, nil) ==
               {:run, {:install, allocation(), artifact(e1()), e1()}}

      installed = %{absent | installation: {:present, installation(e1())}}

      assert Reconcile.next(spec(), installed, nil) ==
               {:run, {:start, allocation(), installation(e1())}}
    end
  end
end
