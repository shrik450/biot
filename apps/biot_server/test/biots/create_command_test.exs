defmodule Biot.Server.Biots.CreateCommandTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.Digest
  alias Biot.Protocol.NodeId
  alias Biot.Server.Biots.Create
  alias Biot.Server.Biots.CreationFingerprint
  alias Biot.Server.TestFixtures

  # The command has no parse function yet, so the fingerprint is the only total function over
  # initial_state. It accepts the two states the model names and rejects every other value.
  property "only running and stopped are accepted initial states" do
    check all(state <- StreamData.term()) do
      command = struct!(Create, Map.put(fields(), :initial_state, state))

      if state in [:running, :stopped] do
        assert %Digest{} = CreationFingerprint.compute(command)
      else
        assert_raise FunctionClauseError, fn -> CreationFingerprint.compute(command) end
      end
    end
  end

  property "the two accepted states always give different fingerprints" do
    check all(
            name <- StreamData.string(Enum.concat(?a..?z, ?0..?9), min_length: 1, max_length: 63)
          ) do
      name = TestFixtures.biot_name(name)
      running = struct!(Create, %{fields() | name: name, initial_state: :running})
      stopped = struct!(Create, %{fields() | name: name, initial_state: :stopped})

      refute CreationFingerprint.compute(running) == CreationFingerprint.compute(stopped)
    end
  end

  test "a command that omits the initial state asks for a running biot" do
    assert %Create{initial_state: :running} =
             struct!(Create, Map.delete(fields(), :initial_state))
  end

  defp fields do
    %{
      name: TestFixtures.biot_name("worker"),
      initial_state: :running,
      repository: TestFixtures.repository(),
      environment: TestFixtures.selection(),
      node_id: TestFixtures.id(NodeId, 1)
    }
  end
end
