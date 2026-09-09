defmodule Biot.Protocol.ExecutionRecordsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.TestGenerators, as: Generators

  property "Desired round-trips through its encoded map" do
    check all(value <- Generators.desired()) do
      assert Desired.parse(Desired.encode(value)) == {:ok, value}
    end
  end

  property "ExecutionReport round-trips through its encoded map" do
    check all(value <- execution_report()) do
      assert ExecutionReport.parse(ExecutionReport.encode(value)) == {:ok, value}
    end
  end

  property "ExecutionSpec round-trips through its encoded map" do
    check all(value <- execution_spec()) do
      assert ExecutionSpec.parse(ExecutionSpec.encode(value)) == {:ok, value}
    end
  end

  property "BiotSpec round-trips through its encoded map" do
    check all(value <- biot_spec()) do
      assert BiotSpec.parse(BiotSpec.encode(value)) == {:ok, value}
    end
  end

  property "every execution record parser rejects arbitrary maps without raising" do
    check all(value <- StreamData.map_of(StreamData.term(), StreamData.term(), max_length: 8)) do
      for module <- record_modules() do
        assert_parse_result(module, module.parse(value))
      end
    end
  end

  property "every execution record parser rejects arbitrary terms without raising" do
    check all(value <- StreamData.term()) do
      for module <- record_modules() do
        assert_parse_result(module, module.parse(value))
      end
    end
  end

  property "every execution record parser rejects an encoding missing one key" do
    check all(
            {module, encoded} <- encoded_record(),
            key <- StreamData.member_of(Map.keys(encoded))
          ) do
      assert_parse_result(module, module.parse(Map.delete(encoded, key)))
    end
  end

  property "every execution record parser survives one replaced encoded value" do
    check all(
            {module, encoded} <- encoded_record(),
            key <- StreamData.member_of(Map.keys(encoded)),
            replacement <- StreamData.term()
          ) do
      assert_parse_result(module, module.parse(Map.put(encoded, key, replacement)))
    end
  end

  test "ExecutionSpec rejects an environment that the desired execution does not select" do
    other_environment_id = pick(Generators.environment_id())
    spec = pick(execution_spec())

    encoded =
      spec
      |> ExecutionSpec.encode()
      |> put_in(["environment", "id"], to_string(other_environment_id))

    assert ExecutionSpec.parse(encoded) == {:error, :invalid_format}
  end

  test "revisions must be positive integers" do
    report = pick(execution_report())
    spec = pick(biot_spec())

    for bad_revision <- [0, -1, "1", 1.0, nil] do
      encoded = Map.put(ExecutionReport.encode(report), "accepted_revision", bad_revision)
      assert ExecutionReport.parse(encoded) == {:error, :invalid_format}

      encoded = Map.put(BiotSpec.encode(spec), "access_revision", bad_revision)
      assert BiotSpec.parse(encoded) == {:error, :invalid_format}
    end
  end

  test "an unknown data state is rejected" do
    report = pick(execution_report())
    encoded = Map.put(ExecutionReport.encode(report), "data", "vanished")

    assert ExecutionReport.parse(encoded) == {:error, :invalid_format}
  end

  test "ExecutionReport rejects the removed access progress field" do
    report = pick(execution_report())

    encoded = Map.put(ExecutionReport.encode(report), "applied_access_revision", 1)
    assert ExecutionReport.parse(encoded) == {:error, :invalid_format}
  end

  test "a present container without an incarnation is rejected" do
    assert ExecutionReport.parse_container(%{"state" => "present"}) == {:error, :invalid_format}
  end

  defp record_modules, do: [Desired, ExecutionReport, ExecutionSpec, BiotSpec]

  defp assert_parse_result(_module, {:ok, _value}), do: :ok
  defp assert_parse_result(_module, {:error, reason}) when is_atom(reason), do: :ok

  defp assert_parse_result(module, result) do
    flunk("#{inspect(module)} returned #{inspect(result)}")
  end

  defp encoded_record do
    StreamData.one_of([
      StreamData.map(Generators.desired(), &{Desired, Desired.encode(&1)}),
      StreamData.map(execution_report(), &{ExecutionReport, ExecutionReport.encode(&1)}),
      StreamData.map(execution_spec(), &{ExecutionSpec, ExecutionSpec.encode(&1)}),
      StreamData.map(biot_spec(), &{BiotSpec, BiotSpec.encode(&1)})
    ])
  end

  defp execution_report do
    gen all(
          accepted_revision <- StreamData.positive_integer(),
          installed_environment_id <-
            StreamData.one_of([StreamData.constant(nil), Generators.environment_id()]),
          container <- container(),
          data <- StreamData.member_of(ExecutionReport.data_states()),
          failure <- reported_failure()
        ) do
      %ExecutionReport{
        accepted_revision: accepted_revision,
        installed_environment_id: installed_environment_id,
        container: container,
        data: data,
        failure: failure
      }
    end
  end

  defp container do
    StreamData.one_of([
      StreamData.constant(:unknown),
      StreamData.constant(:absent),
      gen all(
            incarnation_id <- Generators.incarnation_id(),
            container_state <- Generators.container_state()
          ) do
        {:present, incarnation_id, container_state}
      end
    ])
  end

  defp reported_failure do
    StreamData.one_of([
      StreamData.constant(nil),
      gen all(
            target_revision <- StreamData.positive_integer(),
            failure <- Generators.failure()
          ) do
        {target_revision, failure}
      end
    ])
  end

  defp execution_spec do
    gen all(
          biot_id <- Generators.biot_id(),
          repository <- Generators.repository_source(),
          revision <- StreamData.positive_integer(),
          state <- StreamData.member_of(Desired.states()),
          environment_id <- Generators.environment_id(),
          selection <- Generators.environment_selection()
        ) do
      %ExecutionSpec{
        biot_id: biot_id,
        repository: repository,
        desired: %Desired{revision: revision, state: state, environment_id: environment_id},
        environment: %{id: environment_id, selection: selection}
      }
    end
  end

  defp biot_spec do
    gen all(
          execution <- execution_spec(),
          access_revision <- StreamData.positive_integer()
        ) do
      %BiotSpec{execution: execution, access_revision: access_revision}
    end
  end
end
