defmodule Biot.Protocol.DesiredTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.TestGenerators, as: Generators

  @current_environment_uuid "550e8400-e29b-41d4-a716-446655440000"
  @next_environment_uuid "6ba7b810-9dad-41d1-80b4-00c04fd430c8"

  setup_all do
    {:ok, current_environment} = EnvironmentId.parse(@current_environment_uuid)
    {:ok, next_environment} = EnvironmentId.parse(@next_environment_uuid)
    %{current_environment: current_environment, next_environment: next_environment}
  end

  test "transition follows every state and change pair", context do
    current = context.current_environment
    next = context.next_environment

    cases = [
      {:stopped, :start, {:changed, :running, current}},
      {:stopped, :stop, :unchanged},
      {:stopped, {:update_environment, next}, {:changed, :stopped, next}},
      {:stopped, :destroy, {:changed, :destroyed, current}},
      {:running, :start, :unchanged},
      {:running, :stop, {:changed, :stopped, current}},
      {:running, {:update_environment, next}, {:changed, :running, next}},
      {:running, :destroy, {:changed, :destroyed, current}},
      {:destroyed, :start, {:error, :destroyed}},
      {:destroyed, :stop, {:error, :destroyed}},
      {:destroyed, {:update_environment, next}, {:error, :destroyed}},
      {:destroyed, :destroy, :unchanged}
    ]

    for {state, change, expected} <- cases do
      desired = %Desired{revision: 7, state: state, environment_id: current}
      result = Desired.transition(desired, change)

      case expected do
        {:changed, expected_state, expected_environment} ->
          assert {:changed, changed} = result
          assert changed.state == expected_state
          assert changed.environment_id == expected_environment
          assert changed.revision == 8

        other ->
          assert result == other
      end
    end
  end

  property "a changed transition increases revision by exactly one" do
    check all(
            revision <- StreamData.positive_integer(),
            state <- StreamData.member_of([:running, :stopped, :destroyed]),
            next_uuid <- Generators.canonical_uuid(),
            change_kind <- StreamData.member_of([:start, :stop, :update_environment, :destroy])
          ) do
      {:ok, current_environment} = EnvironmentId.parse(@current_environment_uuid)
      {:ok, next_environment} = EnvironmentId.parse(next_uuid)
      desired = %Desired{revision: revision, state: state, environment_id: current_environment}

      change =
        case change_kind do
          :update_environment -> {:update_environment, next_environment}
          other -> other
        end

      case Desired.transition(desired, change) do
        {:changed, changed} -> assert changed.revision == revision + 1
        :unchanged -> :ok
        {:error, :destroyed} -> :ok
      end
    end
  end
end
