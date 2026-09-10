defmodule Biot.Node.ReconcileSequencesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Reconcile

  describe "create to running (docs/model.md section 9)" do
    test "walks allocate, initialize, resolve, prepare, install, start, then settles" do
      spec = spec()

      nothing_owned = state()
      assert Reconcile.next(spec, nothing_owned, nil) == {:run, {:allocate, biot_id()}}

      allocated = %{nothing_owned | data: {:uninitialized, fresh_allocation()}}

      assert Reconcile.next(spec, allocated, nil) ==
               {:run, {:initialize, fresh_allocation(), repository()}}

      initialized = %{allocated | data: {:present, allocation()}}

      assert Reconcile.next(spec, initialized, nil) ==
               {:run, {:resolve, e1(), selection(), allocation()}}

      resolved = %{initialized | resolutions: %{e1() => {:present, resolution(e1())}}}

      assert Reconcile.next(spec, resolved, nil) == {:run, {:prepare, e1(), manifest()}}

      prepared = %{resolved | prepared: %{e1() => {:present, artifact(e1())}}}

      assert Reconcile.next(spec, prepared, nil) ==
               {:run, {:install, allocation(), artifact(e1()), e1()}}

      installed = %{prepared | installation: {:present, installation(e1())}}

      assert Reconcile.next(spec, installed, nil) ==
               {:run, {:start, allocation(), installation(e1())}}

      running = %{installed | container: running(e1())}
      assert Reconcile.next(spec, running, nil) == :settled
    end

    test "a restarted controller continues from the first unmet condition, never from the clone" do
      # Process memory is gone but the allocation metadata and the installed artifact remain.
      recovered = %{settled(e1()) | container: :absent}

      assert Reconcile.next(spec(), recovered, nil) ==
               {:run, {:start, allocation(), installation(e1())}}
    end
  end

  describe "stop then start" do
    test "the stop observes absence and the later start creates a new incarnation" do
      stopped = spec(state: :stopped, revision: 2)

      assert Reconcile.next(stopped, settled(e1()), nil) ==
               {:run, {:retire, incarnation()}}

      absent = %{settled(e1()) | container: :absent}
      assert Reconcile.next(stopped, absent, nil) == :settled

      started = spec(state: :running, revision: 3)

      assert Reconcile.next(started, absent, nil) ==
               {:run, {:start, allocation(), installation(e1())}}

      new_incarnation = %{absent | container: container(biot_id(), e1(), :running)}
      assert Reconcile.next(started, new_incarnation, nil) == :settled
    end
  end

  describe "update environment" do
    test "prepares, retires, installs after absence, starts, then releases the old environment" do
      spec = spec(environment_id: e2(), revision: 2)

      resolved_both = %{
        settled(e1())
        | resolutions: %{
            e1() => {:present, resolution(e1())},
            e2() => {:present, resolution(e2())}
          }
      }

      assert Reconcile.next(spec, resolved_both, nil) ==
               {:run, {:prepare, e2(), manifest()}}

      prepared_both = %{
        resolved_both
        | prepared: %{
            e1() => {:present, artifact(e1())},
            e2() => {:present, artifact(e2())}
          }
      }

      assert Reconcile.next(spec, prepared_both, nil) == {:run, {:retire, incarnation()}}

      absent = %{prepared_both | container: :absent}

      assert Reconcile.next(spec, absent, nil) ==
               {:run, {:install, allocation(), artifact(e2()), e2()}}

      installed = %{absent | installation: {:present, installation(e2())}}

      assert Reconcile.next(spec, installed, nil) ==
               {:run, {:start, allocation(), installation(e2())}}

      running = %{installed | container: running(e2())}

      # Only once every desired-state step is ready does the cleanup phase give e1 back.
      assert Reconcile.next(spec, running, nil) == {:run, {:release_environment, e1()}}

      released = %{
        running
        | prepared: %{e2() => {:present, artifact(e2())}},
          resolutions: %{e2() => {:present, resolution(e2())}}
      }

      assert Reconcile.next(spec, released, nil) == :settled
    end
  end

  describe "destroy" do
    test "retires, releases the environment, removes data, releases the allocation, then settles" do
      spec = spec(state: :destroyed, revision: 3)

      assert Reconcile.next(spec, settled(e1()), nil) == {:run, {:retire, incarnation()}}

      retired = %{settled(e1()) | container: :absent}
      assert Reconcile.next(spec, retired, nil) == {:run, {:release_environment, e1()}}

      released = %{retired | prepared: %{}, resolutions: %{}}
      assert Reconcile.next(spec, released, nil) == {:run, {:remove_data, allocation()}}

      removed = %{released | data: {:uninitialized, fresh_allocation()}, installation: nil}

      assert Reconcile.next(spec, removed, nil) ==
               {:run, {:release_allocation, fresh_allocation()}}

      gone = %{removed | data: :no_allocation}
      assert Reconcile.next(spec, gone, nil) == :settled
    end

    test "remove_data converges over a completion marker whose data are already gone" do
      spec = spec(state: :destroyed, revision: 3)
      lost = state(data: {:lost, allocation()})

      assert Reconcile.next(spec, lost, nil) == {:run, {:remove_data, allocation()}}
    end
  end
end
