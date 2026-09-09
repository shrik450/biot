defmodule Biot.Protocol.Failure do
  @moduledoc "A bounded description of a failed node lifecycle action."

  alias Biot.Protocol.PrivateDiagnosticId

  @enforce_keys [:stage, :code, :retry, :message, :diagnostic_ref]
  defstruct [:stage, :code, :retry, :message, :diagnostic_ref]

  @stages ~w(allocate initialize resolve prepare install start retire remove_data release_allocation inspect)a
  @codes ~w(resource_unavailable invalid_source resolution_failed preparation_failed installation_failed container_failed lost_data inspection_failed)a
  @retries ~w(automatic after_change operator)a

  @type stage :: unquote(Enum.reduce(@stages, &{:|, [], [&1, &2]}))
  @type code :: unquote(Enum.reduce(@codes, &{:|, [], [&1, &2]}))
  @type retry_policy :: unquote(Enum.reduce(@retries, &{:|, [], [&1, &2]}))
  @type t :: %__MODULE__{
          stage: stage(),
          code: code(),
          retry: retry_policy(),
          message: String.t(),
          diagnostic_ref: PrivateDiagnosticId.t() | nil
        }

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = failure) do
    %{
      "stage" => Atom.to_string(failure.stage),
      "code" => Atom.to_string(failure.code),
      "retry" => Atom.to_string(failure.retry),
      "message" => failure.message,
      "diagnostic_ref" => encode_diagnostic_ref(failure.diagnostic_ref)
    }
  end

  @spec parse(term()) :: {:ok, t()} | {:error, atom()}
  def parse(value) when is_map(value) do
    with {:ok, stage} <- Map.fetch(value, "stage"),
         {:ok, stage} <- parse_enum(stage, @stages),
         {:ok, code} <- Map.fetch(value, "code"),
         {:ok, code} <- parse_enum(code, @codes),
         {:ok, retry_policy} <- Map.fetch(value, "retry"),
         {:ok, retry_policy} <- parse_enum(retry_policy, @retries),
         {:ok, message} when is_binary(message) <- Map.fetch(value, "message"),
         {:ok, diagnostic_ref} <- Map.fetch(value, "diagnostic_ref"),
         {:ok, diagnostic_ref} <- parse_diagnostic_ref(diagnostic_ref) do
      {:ok,
       %__MODULE__{
         stage: stage,
         code: code,
         retry: retry_policy,
         message: message,
         diagnostic_ref: diagnostic_ref
       }}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  defp parse_enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_format}
      parsed -> {:ok, parsed}
    end
  end

  defp parse_enum(_value, _allowed), do: {:error, :invalid_format}

  defp parse_diagnostic_ref(nil), do: {:ok, nil}
  defp parse_diagnostic_ref(value), do: PrivateDiagnosticId.parse(value)

  defp encode_diagnostic_ref(nil), do: nil
  defp encode_diagnostic_ref(value), do: PrivateDiagnosticId.to_string(value)
end
