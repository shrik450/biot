defmodule Biot.Protocol.Wire do
  @moduledoc "Encodes and decodes strict JSON messages for a negotiated protocol version. Handshake messages always use the fixed version 1 shape."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Frame
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.Limits
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.Message
  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Protocol.ParsedList
  alias Biot.Protocol.Platform
  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.Version

  @modules %{
    1 => [
      Message.SynchronizeBegin,
      Message.SynchronizeItem,
      Message.SynchronizeEnd,
      Message.Desired,
      Message.Diagnostic,
      Message.RuntimeLogs,
      Message.Synchronized,
      Message.Observation,
      Message.AccessApplied,
      Message.Resolution,
      Message.NodeObservation,
      Message.DiagnosticResult,
      Message.RuntimeLogsResult,
      Message.Heartbeat,
      Message.HeartbeatResponse
    ],
    handshake: [Message.Hello, Message.Connected, Message.Reject]
  }

  @type phase :: :handshake
  @type version :: pos_integer()
  @type context :: phase() | version()
  @type error_reason ::
          :biot_spec_too_large
          | :invalid_json
          | :invalid_message
          | {:invalid_message, atom()}
          | :unknown_message_type
          | :unknown_fields
          | :unsupported_protocol_version

  @spec encode(struct(), context()) :: {:ok, binary()} | {:error, error_reason()}
  def encode(message, context) do
    with {:ok, module} <- message_module(message, context),
         {:ok, payload} <- encode_payload(module, message, context),
         {:ok, json} <- Jason.encode(Map.put(payload, "type", module.type())) do
      {:ok, json}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :invalid_message}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec decode(binary(), context()) :: {:ok, struct()} | {:error, error_reason()}
  def decode(json, context) when is_binary(json) do
    with {:ok, value} <- decode_json(json),
         {:ok, type} <- fetch_type(value),
         {:ok, module} <- module_for_type(type, context),
         :ok <- exact_fields(value, module) do
      decode_payload(module, Map.delete(value, "type"), context)
    end
  end

  @spec min_frame_bytes(version()) :: pos_integer()
  # Step 18 adds the encoded secret payload to this minimum.
  def min_frame_bytes(version) do
    Limits.max_biot_spec_bytes(version) + biot_spec_envelope_bytes(version) +
      Frame.overhead_bytes()
  end

  @spec check_frame_limit!(pos_integer()) :: :ok
  def check_frame_limit!(max_frame_bytes) do
    Enum.each(Version.supported(), fn version ->
      minimum = min_frame_bytes(version)

      if max_frame_bytes < minimum do
        raise "max_frame_bytes must be at least #{minimum} bytes for protocol version #{version}; got #{max_frame_bytes}"
      end
    end)
  end

  defp message_module(%{__struct__: module}, context) do
    with {:ok, modules} <- modules(context) do
      if module in modules, do: {:ok, module}, else: {:error, :invalid_message}
    end
  end

  defp message_module(_message, _context), do: {:error, :invalid_message}

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _error -> {:error, :invalid_json}
    end
  end

  defp fetch_type(%{"type" => type}) when is_binary(type), do: {:ok, type}
  defp fetch_type(_value), do: {:error, :invalid_message}

  defp module_for_type(type, context) do
    with {:ok, modules} <- modules(context), do: find_module(type, modules)
  end

  defp modules(context) do
    case Map.fetch(@modules, context) do
      {:ok, modules} -> {:ok, modules}
      :error -> {:error, :unsupported_protocol_version}
    end
  end

  defp find_module(type, modules) do
    case Enum.find(modules, &(&1.type() == type)) do
      nil -> {:error, :unknown_message_type}
      module -> {:ok, module}
    end
  end

  defp exact_fields(value, module) do
    expected = ["type" | struct_fields(module) |> Enum.map(&Atom.to_string/1)] |> MapSet.new()
    actual = value |> Map.keys() |> MapSet.new()
    if actual == expected, do: :ok, else: {:error, :unknown_fields}
  end

  defp struct_fields(module) do
    module.__struct__() |> Map.delete(:__struct__) |> Map.keys()
  end

  defp encode_payload(module, message, context) do
    message
    |> Map.from_struct()
    |> Enum.reduce_while({:ok, %{}}, fn {field, value}, {:ok, payload} ->
      case encode_field(module, field, value, context) do
        {:ok, encoded} -> {:cont, {:ok, Map.put(payload, Atom.to_string(field), encoded)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_payload(module, payload, context) do
    module
    |> struct_fields()
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, attrs} ->
      value = Map.fetch!(payload, Atom.to_string(field))

      case decode_field(module, field, value, context) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(attrs, field, decoded)}}
        {:error, reason} -> {:halt, decode_field_error(reason, field)}
      end
    end)
    |> case do
      {:ok, attrs} -> {:ok, struct!(module, attrs)}
      error -> error
    end
  end

  defp decode_field_error(:biot_spec_too_large, _field),
    do: {:error, :biot_spec_too_large}

  defp decode_field_error(reason, field) when reason != :biot_spec_too_large,
    do: {:error, {:invalid_message, field}}

  @spec_carrying_messages [Message.SynchronizeItem, Message.Desired]

  defp encode_field(Message.SynchronizeItem, :biot_spec, spec, context),
    do: encode_biot_spec(spec, context)

  defp encode_field(Message.Desired, :biot_spec, spec, context),
    do: encode_biot_spec(spec, context)

  defp encode_field(Message.Hello, :registration_id, value, _context),
    do: {:ok, RegistrationId.to_string(value)}

  defp encode_field(Message.Hello, :platform, value, _context),
    do: {:ok, Platform.to_string(value)}

  defp encode_field(Message.Hello, :supported_protocol_versions, versions, _context),
    do: {:ok, versions}

  defp encode_field(Message.Connected, :connection_id, value, _context),
    do: {:ok, ConnectionId.to_string(value)}

  defp encode_field(Message.Connected, :selected_protocol_version, value, _context),
    do: {:ok, value}

  defp encode_field(Message.Reject, :reason, reason, _context),
    do: {:ok, Atom.to_string(reason)}

  defp encode_field(Message.SynchronizeBegin, :connection_id, value, _context),
    do: {:ok, ConnectionId.to_string(value)}

  defp encode_field(Message.SynchronizeBegin, :count, value, _context), do: {:ok, value}

  defp encode_field(Message.SynchronizeEnd, :connection_id, value, _context),
    do: {:ok, ConnectionId.to_string(value)}

  defp encode_field(Message.Diagnostic, :request_id, value, _context), do: {:ok, value}

  defp encode_field(Message.Diagnostic, :diagnostic_id, value, _context),
    do: {:ok, PrivateDiagnosticId.to_string(value)}

  defp encode_field(Message.Diagnostic, field, value, _context)
       when field in [:max_bytes, :timeout_ms],
       do: {:ok, value}

  defp encode_field(Message.RuntimeLogs, :request_id, value, _context), do: {:ok, value}

  defp encode_field(Message.RuntimeLogs, :biot_id, value, _context),
    do: {:ok, BiotId.to_string(value)}

  defp encode_field(Message.RuntimeLogs, field, value, _context)
       when field in [:max_bytes, :timeout_ms],
       do: {:ok, value}

  defp encode_field(Message.Synchronized, :connection_id, value, _context),
    do: {:ok, ConnectionId.to_string(value)}

  defp encode_field(Message.Observation, :biot_id, value, _context),
    do: {:ok, BiotId.to_string(value)}

  defp encode_field(Message.Observation, :execution_report, value, _context),
    do: {:ok, ExecutionReport.encode(value)}

  defp encode_field(Message.AccessApplied, :biot_id, value, _context),
    do: {:ok, BiotId.to_string(value)}

  defp encode_field(Message.AccessApplied, :access_revision, value, _context), do: {:ok, value}

  defp encode_field(Message.Resolution, :environment_id, value, _context),
    do: {:ok, EnvironmentId.to_string(value)}

  defp encode_field(Message.Resolution, :manifest, value, _context),
    do: {:ok, Manifest.encode(value)}

  defp encode_field(Message.NodeObservation, :orphaned_allocations, values, _context),
    do: {:ok, Enum.map(values, &OrphanedAllocation.encode/1)}

  defp encode_field(Message.DiagnosticResult, :request_id, value, _context), do: {:ok, value}

  defp encode_field(Message.DiagnosticResult, :result, :not_found, _context),
    do: {:ok, %{"status" => "not_found"}}

  defp encode_field(Message.DiagnosticResult, :result, {content, truncated}, _context) do
    {:ok,
     %{
       "status" => "found",
       "content" => Base.encode64(content),
       "truncated" => truncated
     }}
  end

  defp encode_field(Message.RuntimeLogsResult, :request_id, value, _context), do: {:ok, value}

  defp encode_field(Message.RuntimeLogsResult, :result, :not_found, _context),
    do: {:ok, %{"status" => "not_found"}}

  defp encode_field(
         Message.RuntimeLogsResult,
         :result,
         {incarnation_id, content, truncated},
         _context
       ) do
    {:ok,
     %{
       "status" => "found",
       "incarnation_id" => IncarnationId.to_string(incarnation_id),
       "content" => Base.encode64(content),
       "truncated" => truncated
     }}
  end

  defp encode_field(module, :challenge, value, _context)
       when module in [Message.Heartbeat, Message.HeartbeatResponse],
       do: {:ok, value}

  defp decode_field(Message.SynchronizeItem, :biot_spec, value, context),
    do: decode_biot_spec(value, context)

  defp decode_field(Message.Desired, :biot_spec, value, context),
    do: decode_biot_spec(value, context)

  defp decode_field(Message.Hello, :registration_id, value, _context),
    do: RegistrationId.parse(value)

  defp decode_field(Message.Hello, :platform, value, _context), do: Platform.parse(value)

  defp decode_field(Message.Hello, :supported_protocol_versions, value, _context),
    do: protocol_versions(value)

  defp decode_field(Message.Connected, :connection_id, value, _context),
    do: ConnectionId.parse(value)

  defp decode_field(Message.Connected, :selected_protocol_version, value, _context),
    do: positive_integer(value)

  defp decode_field(Message.Reject, :reason, value, _context) do
    reject_reason(value)
  end

  defp decode_field(Message.SynchronizeBegin, :connection_id, value, _context),
    do: ConnectionId.parse(value)

  defp decode_field(Message.SynchronizeBegin, :count, value, _context),
    do: non_negative_integer(value)

  defp decode_field(Message.SynchronizeEnd, :connection_id, value, _context),
    do: ConnectionId.parse(value)

  defp decode_field(Message.Diagnostic, :request_id, value, _context),
    do: nonempty_string(value)

  defp decode_field(Message.Diagnostic, :diagnostic_id, value, _context),
    do: PrivateDiagnosticId.parse(value)

  defp decode_field(Message.Diagnostic, field, value, _context)
       when field in [:max_bytes, :timeout_ms],
       do: positive_integer(value)

  defp decode_field(Message.RuntimeLogs, :request_id, value, _context),
    do: nonempty_string(value)

  defp decode_field(Message.RuntimeLogs, :biot_id, value, _context), do: BiotId.parse(value)

  defp decode_field(Message.RuntimeLogs, field, value, _context)
       when field in [:max_bytes, :timeout_ms],
       do: positive_integer(value)

  defp decode_field(Message.Synchronized, :connection_id, value, _context),
    do: ConnectionId.parse(value)

  defp decode_field(Message.Observation, :biot_id, value, _context), do: BiotId.parse(value)

  defp decode_field(Message.Observation, :execution_report, value, _context),
    do: ExecutionReport.parse(value)

  defp decode_field(Message.AccessApplied, :biot_id, value, _context),
    do: BiotId.parse(value)

  defp decode_field(Message.AccessApplied, :access_revision, value, _context),
    do: positive_integer(value)

  defp decode_field(Message.Resolution, :environment_id, value, _context),
    do: EnvironmentId.parse(value)

  defp decode_field(Message.Resolution, :manifest, value, _context), do: Manifest.parse(value)

  defp decode_field(Message.NodeObservation, :orphaned_allocations, values, _context),
    do: ParsedList.parse(values, &OrphanedAllocation.parse/1)

  defp decode_field(Message.DiagnosticResult, :request_id, value, _context),
    do: nonempty_string(value)

  defp decode_field(Message.DiagnosticResult, :result, value, _context),
    do: diagnostic_result(value)

  defp decode_field(Message.RuntimeLogsResult, :request_id, value, _context),
    do: nonempty_string(value)

  defp decode_field(Message.RuntimeLogsResult, :result, value, _context),
    do: runtime_logs_result(value)

  defp decode_field(module, :challenge, value, _context)
       when module in [Message.Heartbeat, Message.HeartbeatResponse],
       do: nonempty_string(value)

  defp reject_reason(value) when is_binary(value) do
    case Enum.find(Message.Reject.reasons(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_format}
      reason -> {:ok, reason}
    end
  end

  defp reject_reason(_value), do: {:error, :invalid_format}

  defp diagnostic_result(%{"status" => "not_found"} = value) when map_size(value) == 1,
    do: {:ok, :not_found}

  defp diagnostic_result(
         %{"status" => "found", "content" => content, "truncated" => truncated} = value
       )
       when map_size(value) == 3 and is_binary(content) and is_boolean(truncated) do
    with {:ok, decoded} <- decode_base64(content), do: {:ok, {decoded, truncated}}
  end

  defp diagnostic_result(_value), do: {:error, :invalid_format}

  defp runtime_logs_result(%{"status" => "not_found"} = value) when map_size(value) == 1,
    do: {:ok, :not_found}

  defp runtime_logs_result(
         %{
           "status" => "found",
           "incarnation_id" => incarnation_id,
           "content" => content,
           "truncated" => truncated
         } = value
       )
       when map_size(value) == 4 and is_binary(content) and is_boolean(truncated) do
    with {:ok, incarnation_id} <- IncarnationId.parse(incarnation_id),
         {:ok, content} <- decode_base64(content) do
      {:ok, {incarnation_id, content, truncated}}
    end
  end

  defp runtime_logs_result(_value), do: {:error, :invalid_format}

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_format}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_format}

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_value), do: {:error, :invalid_format}

  defp valid_positive_integer?(value), do: is_integer(value) and value > 0

  defp protocol_versions(versions) when is_list(versions) and versions != [] do
    if Enum.all?(versions, &valid_positive_integer?/1),
      do: {:ok, versions},
      else: {:error, :invalid_format}
  end

  defp protocol_versions(_value), do: {:error, :invalid_format}

  defp nonempty_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp nonempty_string(_value), do: {:error, :invalid_format}

  defp encode_biot_spec(spec, context) do
    encoded = BiotSpec.encode(spec)

    with :ok <- check_biot_spec_size(encoded, context), do: {:ok, encoded}
  end

  defp decode_biot_spec(value, context) do
    with :ok <- check_biot_spec_size(value, context), do: BiotSpec.parse(value)
  end

  defp check_biot_spec_size(_value, :handshake), do: :ok

  defp check_biot_spec_size(value, version) do
    if encoded_bytes(value) <= Limits.max_biot_spec_bytes(version),
      do: :ok,
      else: {:error, :biot_spec_too_large}
  end

  defp biot_spec_envelope_bytes(version) do
    @spec_carrying_messages
    |> Enum.map(&biot_spec_envelope_bytes(&1, version))
    |> Enum.max()
  end

  defp biot_spec_envelope_bytes(module, version) do
    message = module.__struct__()
    {:ok, ^module} = message_module(message, version)

    payload =
      module
      |> struct_fields()
      |> Map.new(&{Atom.to_string(&1), nil})
      |> Map.put("type", module.type())

    encoded_bytes(payload) - encoded_bytes(nil)
  end

  defp encoded_bytes(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()
end
