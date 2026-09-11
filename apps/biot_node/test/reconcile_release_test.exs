defmodule Biot.Node.ReconcileReleaseTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Reconcile
  alias Biot.Node.Reconcile.Environment

  describe "Environment.release/2 retains what something still needs" do
    test "a live container's environment stays, even for a destroyed biot" do
      state =
        state(
          data: {:present, allocation()},
          container: running(e1()),
          prepared: %{e1() => {:present, artifact(e1())}}
        )

      assert Environment.release(spec(state: :destroyed, revision: 3), state) == :ready
    end

    test "an installation nobody could inspect keeps its environment" do
      state =
        state(
          data: {:present, allocation()},
          installation: {:unknown, installation(e2()), inspection(:installation)},
          prepared: %{e2() => {:present, artifact(e2())}}
        )

      assert Environment.release(spec(), state) == :ready
    end

    test "a lost installation has no artifact left to keep" do
      state =
        state(
          data: {:present, allocation()},
          installation: {:lost, installation(e2())},
          prepared: %{e2() => {:present, artifact(e2())}}
        )

      assert Environment.release(spec(), state) ==
               {:run, {:release_environment, e2(), allocation()}}
    end

    test "nothing is given back while the container is unknown" do
      state =
        state(
          data: {:present, allocation()},
          container: {:unknown, inspection(:container)},
          prepared: %{e2() => {:present, artifact(e2())}},
          resolutions: %{e2() => {:present, resolution(e2())}}
        )

      assert Environment.release(spec(), state) == :ready
      assert Environment.release(spec(state: :destroyed, revision: 3), state) == :ready
    end

    test "an artifact nobody could inspect is not a candidate" do
      state =
        state(
          data: {:present, allocation()},
          prepared: %{e2() => {:unknown, inspection(:prepared)}}
        )

      assert Environment.release(spec(), state) == :ready
    end

    test "a resolution nobody could inspect is not a candidate" do
      state =
        state(
          data: {:present, allocation()},
          resolutions: %{e2() => {:unknown, resolution(e2()), inspection(:resolution)}}
        )

      assert Environment.release(spec(), state) == :ready
    end
  end

  describe "Environment.release/2 gives back what nothing needs" do
    test "a stale prepared artifact" do
      state = %{
        settled(e1())
        | prepared: %{
            e1() => {:present, artifact(e1())},
            e2() => {:present, artifact(e2())}
          }
      }

      assert Environment.release(spec(), state) ==
               {:run, {:release_environment, e2(), allocation()}}
    end

    test "a stale resolution snapshot with no artifact of its own" do
      state = %{
        settled(e1())
        | resolutions: %{
            e1() => {:present, resolution(e1())},
            e2() => {:present, resolution(e2())}
          }
      }

      assert Environment.release(spec(), state) ==
               {:run, {:release_environment, e2(), allocation()}}
    end

    test "a stale resolution snapshot whose artifact nobody could inspect" do
      # `release_environment` gives back both the snapshot and the artifact, and an environment
      # nothing retains is safe to give back whatever inspection saw.
      state = %{
        settled(e1())
        | prepared: %{e2() => {:unknown, inspection(:prepared)}},
          resolutions: %{e2() => {:present, resolution(e2())}}
      }

      assert Environment.release(spec(), state) ==
               {:run, {:release_environment, e2(), allocation()}}
    end

    test "a lost resolution snapshot" do
      state = %{settled(e1()) | resolutions: %{e2() => {:lost, resolution(e2())}}}

      assert Environment.release(spec(), state) ==
               {:run, {:release_environment, e2(), allocation()}}
    end
  end

  describe "reclamation never wins over desired work" do
    test "an install for the desired environment comes before releasing a stale one" do
      state =
        state(
          data: {:present, allocation()},
          resolutions: %{e1() => {:present, resolution(e1())}},
          prepared: %{
            e1() => {:present, artifact(e1())},
            e2() => {:present, artifact(e2())}
          }
        )

      assert Reconcile.next(spec(), state, nil) ==
               {:run, {:install, allocation(), artifact(e1()), e1()}}
    end

    test "retiring a container comes before releasing a stale environment" do
      state = %{
        settled(e1())
        | prepared: %{
            e1() => {:present, artifact(e1())},
            e2() => {:present, artifact(e2())}
          }
      }

      assert Reconcile.next(spec(state: :stopped, revision: 2), state, nil) ==
               {:run, {:retire, incarnation()}}
    end
  end
end
