defmodule Biot.Server.Control.SynchronizationTest do
  use ExUnit.Case, async: true

  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionReport
  alias Biot.Server.Control.Synchronization

  test "every desired state and reported data pair follows the one exclusion rule" do
    for state <- Desired.states(),
        data <- [nil | ExecutionReport.data_states()] do
      expected = not (state == :destroyed and data == :no_allocation)

      assert Synchronization.included?(state, data) == expected,
             "state #{inspect(state)} with data #{inspect(data)}"
    end
  end

  test "a destroyed biot leaves the set only once the node reports no allocation" do
    refute Synchronization.included?(:destroyed, :no_allocation)

    for data <- [nil, :unknown, :uninitialized, :present, :lost] do
      assert Synchronization.included?(:destroyed, data), "data #{inspect(data)}"
    end
  end

  test "a live biot stays in the set whatever the node reports" do
    for state <- [:running, :stopped],
        data <- [nil | ExecutionReport.data_states()] do
      assert Synchronization.included?(state, data),
             "state #{inspect(state)} with data #{inspect(data)}"
    end
  end
end
