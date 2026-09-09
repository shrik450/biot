defmodule Biot.Protocol.CanonicalUuidTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.CanonicalUuid
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.TestGenerators, as: Generators

  @identifier_modules [
    Biot.Protocol.BiotId,
    Biot.Protocol.EnvironmentId,
    Biot.Protocol.NodeId,
    Biot.Protocol.OperationId,
    Biot.Protocol.PrincipalId,
    Biot.Protocol.PrivateDiagnosticId,
    Biot.Protocol.RegistrationId
  ]

  property "canonical UUIDs parse without changing their text" do
    check all(uuid <- Generators.canonical_uuid()) do
      assert CanonicalUuid.parse(uuid) == {:ok, uuid}
    end
  end

  property "every identifier round-trips through its canonical string" do
    check all(uuid <- Generators.canonical_uuid()) do
      for module <- @identifier_modules do
        assert {:ok, identifier} = module.parse(uuid)
        assert module.parse(module.to_string(identifier)) == {:ok, identifier}
        assert Kernel.to_string(identifier) == uuid
      end
    end
  end

  test "UUID parsers reject non-canonical and non-v4 forms" do
    invalid_values = [
      "550E8400-E29B-41D4-A716-446655440000",
      "{550e8400-e29b-41d4-a716-446655440000}",
      "urn:uuid:550e8400-e29b-41d4-a716-446655440000",
      "550e8400e29b41d4a716446655440000",
      "550e8400-e29b-11d4-a716-446655440000",
      "550e8400-e29b-41d4-7716-446655440000",
      "550e8400-e29b-41d4-c716-446655440000",
      "550e8400-e29b-41d4-a716-44665544000",
      "550e8400-e29b-41d4-a716-446655440000\n"
    ]

    for value <- invalid_values, module <- [CanonicalUuid | @identifier_modules] do
      assert module.parse(value) == {:error, :invalid_format}
    end
  end

  test "identifier modules keep the same UUID in different struct types" do
    uuid = "550e8400-e29b-41d4-a716-446655440000"

    assert {:ok, biot_id} = BiotId.parse(uuid)
    assert {:ok, environment_id} = EnvironmentId.parse(uuid)
    assert is_struct(biot_id, BiotId)
    assert is_struct(environment_id, EnvironmentId)
    assert BiotId.to_string(biot_id) == EnvironmentId.to_string(environment_id)
  end
end
