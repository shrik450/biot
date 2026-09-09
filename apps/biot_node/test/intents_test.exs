defmodule Biot.Node.IntentsTest do
  use ExUnit.Case, async: false

  alias Biot.Node.Intents
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  setup do
    :ok = Intents.replace([])
    on_exit(fn -> Intents.replace([]) end)
  end

  test "put, replace, get, and all expose the current intent set to every process" do
    first = spec(1)
    second = spec(2)

    assert :ok = Intents.put(first)
    assert Intents.get(first.execution.biot_id) == first
    assert Intents.all() == [first]

    assert :ok = Intents.replace([second])
    assert Intents.get(first.execution.biot_id) == nil
    assert Intents.get(second.execution.biot_id) == second
    assert Intents.all() == [second]

    task = Task.async(fn -> {Intents.get(second.execution.biot_id), Intents.all()} end)
    assert Task.await(task) == {second, [second]}
  end

  test "per-biot and all-biots subscribers receive the same change" do
    first = spec(3)
    parent = self()

    per_biot =
      spawn_link(fn ->
        {:ok, _pid} = Intents.subscribe(first.execution.biot_id)
        send(parent, :per_biot_subscribed)

        receive do
          message -> send(parent, {:per_biot, message})
        end
      end)

    all_biots =
      spawn_link(fn ->
        {:ok, _pid} = Intents.subscribe_all()
        send(parent, :all_biots_subscribed)

        receive do
          message -> send(parent, {:all_biots, message})
        end
      end)

    assert_receive :per_biot_subscribed
    assert_receive :all_biots_subscribed
    assert :ok = Intents.put(first)

    expected = {:intent_changed, first.execution.biot_id, first}
    assert_receive {:per_biot, ^expected}
    assert_receive {:all_biots, ^expected}

    assert Process.alive?(per_biot) == false
    assert Process.alive?(all_biots) == false
  end

  test "replace publishes additions, changes, and removals but not unchanged specs" do
    first = spec(4)
    changed = %{first | access_revision: first.access_revision + 1}
    second = spec(5)

    {:ok, _pid} = Intents.subscribe_all()
    assert :ok = Intents.replace([first])
    assert_receive {:intent_changed, first_id, ^first}
    assert first_id == first.execution.biot_id

    assert :ok = Intents.replace([first])
    refute_receive {:intent_changed, _biot_id, _spec}

    assert :ok = Intents.replace([changed, second])
    assert_receive {:intent_changed, changed_id, ^changed}
    assert changed_id == first.execution.biot_id
    assert_receive {:intent_changed, second_id, ^second}
    assert second_id == second.execution.biot_id

    assert :ok = Intents.replace([second])
    assert_receive {:intent_changed, removed_id, nil}
    assert removed_id == first.execution.biot_id
  end

  defp spec(number) do
    biot_id = id(BiotId, number)
    environment_id = id(EnvironmentId, number + 100)
    {:ok, repository} = RepositorySource.parse("https://example.test/project-#{number}.git")

    selection = %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: [],
      project_context: nil
    }

    %BiotSpec{
      execution: %ExecutionSpec{
        biot_id: biot_id,
        repository: repository,
        desired: %Desired{
          revision: number,
          state: :running,
          environment_id: environment_id
        },
        environment: %{id: environment_id, selection: selection}
      },
      access_revision: number
    }
  end

  defp id(module, number) do
    value = "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
    {:ok, identifier} = module.parse(value)
    identifier
  end
end
