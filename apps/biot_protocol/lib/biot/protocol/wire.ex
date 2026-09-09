defmodule Biot.Protocol.Wire do
  @moduledoc "Encodes and decodes strict JSON messages for a negotiated protocol version. Handshake messages always use the fixed version 1 shape."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.Message
  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Protocol.ParsedList
  alias Biot.Protocol.Platform
  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Protocol.RegistrationId

  @modules %{
    1 => [
      Message.Synchronize,
      Message.Desired,
      Message.Diagnostic,
      Message.Synchronized,
      Message.Observation,
      Message.Resolution,
      Message.NodeObservation,
      Message.DiagnosticResult,
      Message.Heartbeat,
      Message.HeartbeatResponse
    ],
    handshake: [Message.Hello, Message.Connected, Message.Reject]
  }

  @type phase :: :handshake
  @type version :: pos_integer()
  @type context :: phase() | version()
  @type error_reason ::
          :invalid_json
          | :invalid_message
          | {:invalid_message, atom()}
          | :unknown_message_type
          | :unknown_fields
          | :unsupported_protocol_version

  @spec encode(struct(), context()) :: {:ok, binary()} | {:error, error_reason()}
  def encode(message, context) do
    with {:ok, module} <- message_module(message, context),
         {:ok, payload} <- encode_payload(module, message),
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
      decode_payload(module, Map.delete(value, "type"))
    end
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

  defp encode_payload(module, message) do
    message
    |> Map.from_struct()
    |> Enum.reduce_while({:ok, %{}}, fn {field, value}, {:ok, payload} ->
      case encode_field(module, field, value) do
        {:ok, encoded} -> {:cont, {:ok, Map.put(payload, Atom.to_string(field), encoded)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_payload(module, payload) do
    module
    |> struct_fields()
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, attrs} ->
      value = Map.fetch!(payload, Atom.to_string(field))

      case decode_field(module, field, value) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(attrs, field, decoded)}}
        {:error, _reason} -> {:halt, {:error, {:invalid_message, field}}}
      end
    end)
    |> case do
      {:ok, attrs} -> {:ok, struct!(module, attrs)}
      error -> error
    end
  end

  defp encode_field(Message.Hello, :registration_id, value),
    do: {:ok, RegistrationId.to_string(value)}

  defp encode_field(Message.Hello, :platform, value), do: {:ok, Platform.to_string(value)}

  defp encode_field(Message.Hello, :supported_protocol_versions, versions), do: {:ok, versions}

  defp encode_field(Message.Connected, :connection_id, value),
    do: {:ok, ConnectionId.to_string(value)}

  defp encode_field(Message.Connected, :selected_protocol_version, value), do: {:ok, value}

  defp encode_field(Message.Reject, :reason, reason), do: {:ok, Atom.to_string(reason)}

  defp encode_field(Message.Synchronize, :connection_id, value),
    do: {:ok, ConnectionId.to_string(value)}

  defp encode_field(Message.Synchronize, :biot_specs, specs),
    do: {:ok, Enum.map(specs, &BiotSpec.encode/1)}

  defp encode_field(Message.Desired, :biot_spec, spec), do: {:ok, BiotSpec.encode(spec)}
  defp encode_field(Message.Diagnostic, :request_id, value), do: {:ok, value}

  defp encode_field(Message.Diagnostic, :diagnostic_id, value),
    do: {:ok, PrivateDiagnosticId.to_string(value)}

  defp encode_field(Message.Diagnostic, field, value) when field in [:max_bytes, :timeout_ms],
    do: {:ok, value}

  defp encode_field(Message.Synchronized, :connection_id, value),
    do: {:ok, ConnectionId.to_string(value)}

  defp encode_field(Message.Observation, :biot_id, value), do: {:ok, BiotId.to_string(value)}

  defp encode_field(Message.Observation, :execution_report, value),
    do: {:ok, ExecutionReport.encode(value)}

  defp encode_field(Message.Resolution, :environment_id, value),
    do: {:ok, EnvironmentId.to_string(value)}

  defp encode_field(Message.Resolution, :manifest, value), do: {:ok, Manifest.encode(value)}

  defp encode_field(Message.NodeObservation, :orphaned_allocations, values),
    do: {:ok, Enum.map(values, &OrphanedAllocation.encode/1)}

  defp encode_field(Message.DiagnosticResult, :request_id, value), do: {:ok, value}

  defp encode_field(Message.DiagnosticResult, :result, :not_found),
    do: {:ok, %{"status" => "not_found"}}

  defp encode_field(Message.DiagnosticResult, :result, {content, truncated}) do
    {:ok,
     %{
       "status" => "found",
       "content" => Base.encode64(content),
       "truncated" => truncated
     }}
  end

  defp encode_field(module, :challenge, value)
       when module in [Message.Heartbeat, Message.HeartbeatResponse],
       do: {:ok, value}

  defp decode_field(Message.Hello, :registration_id, value), do: RegistrationId.parse(value)
  defp decode_field(Message.Hello, :platform, value), do: Platform.parse(value)

  defp decode_field(Message.Hello, :supported_protocol_versions, value),
    do: protocol_versions(value)

  defp decode_field(Message.Connected, :connection_id, value), do: ConnectionId.parse(value)

  defp decode_field(Message.Connected, :selected_protocol_version, value),
    do: positive_integer(value)

  defp decode_field(Message.Reject, :reason, value) do
    reject_reason(value)
  end

  defp decode_field(Message.Synchronize, :connection_id, value), do: ConnectionId.parse(value)

  defp decode_field(Message.Synchronize, :biot_specs, values),
    do: ParsedList.parse(values, &BiotSpec.parse/1)

  defp decode_field(Message.Desired, :biot_spec, value), do: BiotSpec.parse(value)
  defp decode_field(Message.Diagnostic, :request_id, value), do: nonempty_string(value)

  defp decode_field(Message.Diagnostic, :diagnostic_id, value),
    do: PrivateDiagnosticId.parse(value)

  defp decode_field(Message.Diagnostic, field, value) when field in [:max_bytes, :timeout_ms],
    do: positive_integer(value)

  defp decode_field(Message.Synchronized, :connection_id, value), do: ConnectionId.parse(value)
  defp decode_field(Message.Observation, :biot_id, value), do: BiotId.parse(value)

  defp decode_field(Message.Observation, :execution_report, value),
    do: ExecutionReport.parse(value)

  defp decode_field(Message.Resolution, :environment_id, value), do: EnvironmentId.parse(value)
  defp decode_field(Message.Resolution, :manifest, value), do: Manifest.parse(value)

  defp decode_field(Message.NodeObservation, :orphaned_allocations, values),
    do: ParsedList.parse(values, &OrphanedAllocation.parse/1)

  defp decode_field(Message.DiagnosticResult, :request_id, value), do: nonempty_string(value)

  defp decode_field(Message.DiagnosticResult, :result, value), do: diagnostic_result(value)

  defp decode_field(module, :challenge, value)
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
    case Base.decode64(content) do
      {:ok, decoded} -> {:ok, {decoded, truncated}}
      :error -> {:error, :invalid_format}
    end
  end

  defp diagnostic_result(_value), do: {:error, :invalid_format}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_format}

  defp valid_positive_integer?(value), do: is_integer(value) and value > 0

  defp protocol_versions(versions) when is_list(versions) and versions != [] do
    if Enum.all?(versions, &valid_positive_integer?/1),
      do: {:ok, versions},
      else: {:error, :invalid_format}
  end

  defp protocol_versions(_value), do: {:error, :invalid_format}

  defp nonempty_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp nonempty_string(_value), do: {:error, :invalid_format}
end
