defmodule Biot.Protocol.ControlProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  require Record

  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Certificates
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.Frame
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.Liveness
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.Message
  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Protocol.PeerIdentity
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.Platform
  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretValue
  alias Biot.Protocol.SourceSelector
  alias Biot.Protocol.TestGenerators, as: Generators
  alias Biot.Protocol.Version
  alias Biot.Protocol.Wire

  Record.defrecordp(
    :certificate,
    Record.extract(:Certificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :tbs_certificate,
    Record.extract(:TBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  property "frames round-trip arbitrary binary payloads" do
    check all(payload <- StreamData.binary(max_length: 8_192)) do
      encoded = IO.iodata_to_binary(Frame.encode(payload))
      assert Frame.decode(encoded, 8_192) == {:ok, [payload], <<>>}
    end
  end

  test "frame decoding preserves partial input and accepts zero-length frames" do
    frame = IO.iodata_to_binary(Frame.encode("payload"))

    for length <- 0..(byte_size(frame) - 1) do
      partial = binary_part(frame, 0, length)
      assert Frame.decode(partial, 100) == {:ok, [], partial}
    end

    assert Frame.decode(<<0::unsigned-big-32>>, 100) == {:ok, [<<>>], <<>>}
  end

  test "frame decoding returns two frames and a trailing remainder" do
    buffer = IO.iodata_to_binary([Frame.encode("one"), Frame.encode("two"), <<0, 0>>])
    assert Frame.decode(buffer, 100) == {:ok, ["one", "two"], <<0, 0>>}
  end

  test "an oversized frame is rejected from its header alone" do
    assert Frame.decode(<<101::unsigned-big-32>>, 100) == {:error, {:frame_too_large, 101}}
  end

  test "every control message round-trips in its context" do
    for {context, message} <- messages() do
      assert {:ok, encoded} = Wire.encode(message, context)
      assert Wire.decode(encoded, context) == {:ok, message}
    end
  end

  property "the four step 13 messages round-trip through version 1" do
    check all(message <- step_13_message()) do
      assert {:ok, encoded} = Wire.encode(message, 1)
      assert Wire.decode(encoded, 1) == {:ok, message}
      assert {:error, handshake_reason} = Wire.encode(message, :handshake)
      assert is_atom(handshake_reason)
      assert Wire.decode(encoded, :handshake) == {:error, :unknown_message_type}
    end
  end

  property "the four step 13 messages reject damaged maps without raising" do
    check all(
            message <- step_13_message(),
            replacement <- json_term(),
            remove? <- StreamData.boolean()
          ) do
      {:ok, encoded} = Wire.encode(message, 1)
      map = Jason.decode!(encoded)
      field = Enum.random(Map.keys(map))
      damaged = if remove?, do: Map.delete(map, field), else: Map.put(map, field, replacement)
      assert_wire_result(damaged |> Jason.encode!() |> Wire.decode(1))
    end
  end

  test "every reject reason round-trips through the wire codec" do
    assert Message.Reject.reasons() == [
             :unsupported_protocol_version,
             :registration_rejected,
             :registration_retired,
             :registration_abandoned,
             :unknown_stream
           ]

    for reason <- Message.Reject.reasons() do
      reject = %Message.Reject{reason: reason}
      assert {:ok, encoded} = Wire.encode(reject, :handshake)
      assert Wire.decode(encoded, :handshake) == {:ok, reject}
    end
  end

  property "reject decoding never raises for random JSON terms" do
    check all(value <- json_term()) do
      assert_wire_result(value |> Jason.encode!() |> Wire.decode(:handshake))
    end
  end

  property "reject decoding never raises when a valid encoding loses or changes one field" do
    json_values = json_term()

    check all(
            reason <- StreamData.member_of(Message.Reject.reasons()),
            field <- StreamData.member_of(["type", "reason"]),
            replacement <- json_values,
            remove? <- StreamData.boolean()
          ) do
      {:ok, encoded} = Wire.encode(%Message.Reject{reason: reason}, :handshake)
      decoded = Jason.decode!(encoded)

      changed =
        if remove?, do: Map.delete(decoded, field), else: Map.put(decoded, field, replacement)

      assert_wire_result(changed |> Jason.encode!() |> Wire.decode(:handshake))
    end
  end

  test "messages from the wrong phase are rejected" do
    observation = find_message(Message.Observation)
    hello = find_message(Message.Hello)

    assert {:ok, encoded} = Wire.encode(observation, 1)
    assert Wire.decode(encoded, :handshake) == {:error, :unknown_message_type}

    assert {:ok, encoded} = Wire.encode(hello, :handshake)
    assert Wire.decode(encoded, 1) == {:error, :unknown_message_type}
  end

  test "unknown versions are rejected for encoding and decoding" do
    heartbeat = find_message(Message.Heartbeat)
    assert Wire.encode(heartbeat, 2) == {:error, :unsupported_protocol_version}

    assert {:ok, encoded} = Wire.encode(heartbeat, 1)
    assert Wire.decode(encoded, 2) == {:error, :unsupported_protocol_version}
  end

  test "top-level messages reject unknown, missing, and wrongly typed fields without raising" do
    for {context, message} <- messages() do
      {:ok, encoded} = Wire.encode(message, context)
      decoded = Jason.decode!(encoded)
      fields = Map.keys(decoded) -- ["type"]

      assert_decode_error(Map.put(decoded, "unknown", true), context)

      for field <- fields do
        assert_decode_error(Map.delete(decoded, field), context)
        assert_decode_error(Map.put(decoded, field, wrong_value(decoded[field])), context)
      end
    end
  end

  test "nested protocol records reject unknown fields" do
    cases = [
      {Message.Desired, ["biot_spec"]},
      {Message.Observation, ["execution_report"]},
      {Message.Resolution, ["manifest"]},
      {Message.Desired, ["biot_spec", "execution"]},
      {Message.Observation, ["execution_report", "container"]}
    ]

    for {module, path} <- cases do
      message = find_message(module)
      {:ok, encoded} = Wire.encode(message, 1)
      decoded = Jason.decode!(encoded)
      changed = put_nested(decoded, path, &Map.put(&1, "unknown", true))
      assert_decode_error(changed, 1)
    end
  end

  test "runtime log results reject malformed found and not-found shapes" do
    incarnation_id = incarnation_id(6)

    found = %{
      "type" => "runtime_logs_result",
      "request_id" => "request",
      "result" => %{
        "status" => "found",
        "incarnation_id" => to_string(incarnation_id),
        "content" => Base.encode64(<<0, 1, 2>>),
        "truncated" => false
      }
    }

    invalid_results = [
      Map.put(found["result"], "unknown", true),
      Map.delete(found["result"], "content"),
      Map.put(found["result"], "incarnation_id", "bad"),
      Map.put(found["result"], "content", "not base64"),
      Map.put(found["result"], "truncated", 0),
      %{"status" => "not_found", "content" => "extra"},
      %{"status" => "missing"}
    ]

    for result <- invalid_results do
      assert_decode_error(Map.put(found, "result", result), 1)
    end
  end

  property "wire decoding never raises for random binary input" do
    check all(value <- StreamData.binary(max_length: 2_048)) do
      assert_wire_result(Wire.decode(value, context_for(value)))
    end
  end

  property "wire decoding never raises for random JSON maps" do
    scalar =
      StreamData.one_of([
        StreamData.string(:printable, max_length: 40),
        StreamData.integer(),
        StreamData.boolean(),
        StreamData.constant(nil)
      ])

    check all(
            value <- StreamData.map_of(StreamData.string(:alphanumeric, max_length: 20), scalar)
          ) do
      assert_wire_result(value |> Jason.encode!() |> Wire.decode(1))
    end
  end

  test "version selection chooses the highest common version without depending on offer order" do
    cases = [
      {[], [1], {:error, :unsupported_protocol_version}},
      {[99], [1], {:error, :unsupported_protocol_version}},
      {[1], [1], {:ok, 1}},
      {[1, 3, 2], [1, 2, 3], {:ok, 3}},
      {[2, 1, 3], [1, 3], {:ok, 3}},
      {[3, 2, 1], [1, 2], {:ok, 2}}
    ]

    for {offered, supported, expected} <- cases do
      assert Version.select_version(offered, supported) == expected
      assert Version.select_version(Enum.reverse(offered), supported) == expected
    end
  end

  test "liveness accepts only the matching binary challenge" do
    assert Liveness.response_matches?("expected", "expected")
    refute Liveness.response_matches?("expected", "other")
    refute Liveness.response_matches?(nil, "other")
  end

  test "platform parsing accepts only supported Linux systems" do
    for value <- ["x86_64-linux", "aarch64-linux"] do
      assert {:ok, platform} = Platform.parse(value)
      assert Platform.to_string(platform) == value
    end

    for value <- ["armv7-linux", "x86_64-darwin", "aarch64-darwin", "", nil, 1] do
      assert {:error, reason} = Platform.parse(value)
      assert reason in [:unsupported_platform, :invalid_format]
    end
  end

  test "the current host reports a supported Linux platform or rejects a non-Linux host" do
    architecture = :erlang.system_info(:system_architecture) |> List.to_string()

    if String.contains?(architecture, "linux") do
      assert {:ok, platform} = Platform.current()
      assert Platform.to_string(platform) in ["x86_64-linux", "aarch64-linux"]
    else
      assert Platform.current() == {:error, :unsupported_platform}
    end
  end

  test "peer identity is the lowercase SHA-256 digest of SubjectPublicKeyInfo DER" do
    directory = temp_directory("peer-identity")
    assert {:ok, _authority} = Certificates.create_authority(directory)
    assert {:ok, node} = Certificates.issue(directory, {:node, "1"})
    der = certificate_der(node.cert)

    decoded = :public_key.der_decode(:Certificate, der)
    tbs = certificate(decoded, :tbsCertificate)
    spki = tbs_certificate(tbs, :subjectPublicKeyInfo)

    expected =
      :public_key.der_encode(:SubjectPublicKeyInfo, spki)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert PeerIdentity.from_certificate(der) == {:ok, expected}
  end

  defp messages do
    registration_id = id(RegistrationId, 1)
    connection_id = id(ConnectionId, 2)
    biot_id = id(BiotId, 3)
    environment_id = id(EnvironmentId, 4)
    diagnostic_id = id(PrivateDiagnosticId, 5)
    incarnation_id = incarnation_id(6)

    orphaned_allocation =
      %OrphanedAllocation{biot_id: biot_id, uid_range: %{start: 100_000, count: 65_536}}

    {:ok, platform} = Platform.parse("aarch64-linux")
    {:ok, repository} = RepositorySource.parse("https://example.test/repo.git")
    {:ok, secret_name} = SecretName.parse("DATABASE_URL")
    {:ok, secret_value} = SecretValue.parse("value\n", 1)
    {:ok, authorization_value} = AuthorizationValue.parse("Bearer token", 1)

    selection = %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: []
    }

    execution = %ExecutionSpec{
      biot_id: biot_id,
      repository: repository,
      desired: %Desired{revision: 7, state: :running, environment_id: environment_id},
      environment: %{id: environment_id, selection: selection}
    }

    spec = %BiotSpec{execution: execution, access_revision: 9}

    report = %ExecutionReport{
      accepted_revision: 7,
      installed_environment_id: environment_id,
      container: :absent,
      data: :present,
      failure: nil,
      waiting_for: nil
    }

    {:ok, pinned} =
      PinnedSource.pin(
        SourceSelector.nixpkgs(),
        String.duplicate("a", 40),
        "sha256-" <> Base.encode64(:binary.copy(<<1>>, 32))
      )

    manifest = Manifest.build(platform, pinned, [])

    [
      {:handshake,
       %Message.Hello{
         registration_id: registration_id,
         supported_protocol_versions: [1],
         platform: platform
       }},
      {:handshake,
       %Message.Connected{connection_id: connection_id, selected_protocol_version: 1}},
      {:handshake, %Message.Reject{reason: :registration_rejected}},
      {1, %Message.SynchronizeBegin{connection_id: connection_id, count: 1}},
      {1, %Message.SynchronizeItem{biot_spec: spec}},
      {1, %Message.SynchronizeEnd{connection_id: connection_id}},
      {1, %Message.Desired{biot_spec: spec}},
      {1,
       %Message.Diagnostic{
         request_id: "request-1",
         diagnostic_id: diagnostic_id,
         max_bytes: 100,
         timeout_ms: 200
       }},
      {1,
       %Message.RuntimeLogs{
         request_id: "request-2",
         biot_id: biot_id,
         max_bytes: 100,
         timeout_ms: 200
       }},
      {1, %Message.Synchronized{connection_id: connection_id}},
      {1, %Message.Observation{biot_id: biot_id, execution_report: report}},
      {1, %Message.AccessApplied{biot_id: biot_id, access_revision: 9}},
      {1, %Message.Resolution{environment_id: environment_id, manifest: manifest}},
      {1, %Message.NodeObservation{orphaned_allocations: [orphaned_allocation]}},
      {1, %Message.DiagnosticResult{request_id: "request-1", result: {<<0, 1, 2>>, true}}},
      {1, %Message.DiagnosticResult{request_id: "request-2", result: :not_found}},
      {1,
       %Message.RuntimeLogsResult{
         request_id: "request-3",
         result: {incarnation_id, <<0, 1, 2>>, true}
       }},
      {1, %Message.RuntimeLogsResult{request_id: "request-4", result: :not_found}},
      {1, %Message.Heartbeat{challenge: "challenge"}},
      {1, %Message.HeartbeatResponse{challenge: "challenge"}},
      {1,
       %Message.DeliverSecret{
         request_id: "request-5",
         biot_id: biot_id,
         name: secret_name,
         value: secret_value,
         timeout_ms: 200
       }},
      {1,
       %Message.RemoveSecret{
         request_id: "request-6",
         biot_id: biot_id,
         name: secret_name,
         timeout_ms: 200
       }},
      {1, %Message.ListSecrets{request_id: "request-7", biot_id: biot_id, timeout_ms: 200}},
      {1,
       %Message.DeliverFetchCredential{
         request_id: "request-8",
         biot_id: biot_id,
         source: repository,
         value: authorization_value,
         timeout_ms: 200
       }},
      {1,
       %Message.RemoveFetchCredential{
         request_id: "request-9",
         biot_id: biot_id,
         source: repository,
         timeout_ms: 200
       }},
      {1, %Message.SecretResult{request_id: "request-10", result: :ok}},
      {1, %Message.SecretResult{request_id: "request-11", result: {:failure, :write_failed}}},
      {1, %Message.SecretListResult{request_id: "request-12", result: {:ok, [secret_name]}}},
      {1, %Message.SecretListResult{request_id: "request-13", result: :no_allocation}},
      {1,
       %Message.FetchCredentialResult{
         request_id: "request-14",
         result: {:failure, :unavailable}
       }}
    ]
  end

  defp step_13_message do
    StreamData.one_of([
      gen all(
            connection_id <- Generators.connection_id(),
            count <- StreamData.non_negative_integer()
          ) do
        %Message.SynchronizeBegin{connection_id: connection_id, count: count}
      end,
      StreamData.map(Generators.biot_spec(), &%Message.SynchronizeItem{biot_spec: &1}),
      StreamData.map(Generators.connection_id(), &%Message.SynchronizeEnd{connection_id: &1}),
      gen all(biot_id <- Generators.biot_id(), revision <- StreamData.positive_integer()) do
        %Message.AccessApplied{biot_id: biot_id, access_revision: revision}
      end
    ])
  end

  defp find_message(module) do
    {_context, message} = Enum.find(messages(), &(elem(&1, 1).__struct__ == module))
    message
  end

  defp wrong_value(value) when is_binary(value), do: 42
  defp wrong_value(value) when is_integer(value), do: "wrong"
  defp wrong_value(value) when is_list(value), do: %{}
  defp wrong_value(value) when is_map(value), do: []
  defp wrong_value(value) when is_boolean(value), do: "wrong"
  defp wrong_value(nil), do: "wrong"

  defp put_nested(map, [key], change), do: Map.update!(map, key, change)

  defp put_nested(map, [key | rest], change) do
    Map.update!(map, key, &put_nested(&1, rest, change))
  end

  defp assert_decode_error(value, context) do
    assert {:error, reason} = value |> Jason.encode!() |> Wire.decode(context)
    assert is_atom(reason) or match?({_, field} when is_atom(field), reason)
  end

  defp assert_wire_result({:ok, message}) when is_struct(message), do: :ok
  defp assert_wire_result({:error, reason}) when is_atom(reason), do: :ok

  defp assert_wire_result({:error, {reason, field}}) when is_atom(reason) and is_atom(field),
    do: :ok

  defp assert_wire_result(result), do: flunk("wire returned #{inspect(result)}")

  defp context_for(value) when rem(byte_size(value), 2) == 0, do: :handshake
  defp context_for(_value), do: 1

  defp json_term do
    scalar =
      StreamData.one_of([
        StreamData.string(:printable, max_length: 40),
        StreamData.integer(),
        StreamData.boolean(),
        StreamData.constant(nil)
      ])

    StreamData.one_of([
      scalar,
      StreamData.list_of(scalar, max_length: 5),
      StreamData.map_of(StreamData.string(:alphanumeric, max_length: 12), scalar, max_length: 5)
    ])
  end

  defp incarnation_id(number) do
    {:ok, id} = IncarnationId.parse(String.pad_leading(Integer.to_string(number), 64, "0"))
    id
  end

  defp id(module, number) do
    value = "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
    {:ok, identifier} = module.parse(value)
    identifier
  end

  defp temp_directory(suffix) do
    directory =
      BiotTest.Temp.directory("biot-step5-#{suffix}")

    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  defp certificate_der(path) do
    path |> File.read!() |> X509.Certificate.from_pem!() |> X509.Certificate.to_der()
  end
end
