defmodule Biot.Protocol.Failure do
  @moduledoc "A bounded description of a failed node lifecycle action."

  alias Biot.Protocol.PrivateDiagnosticId
  alias Biot.Protocol.StrictMap

  @fields ["stage", "code", "retry", "message", "diagnostic_ref"]

  @enforce_keys [:stage, :code, :retry, :message, :diagnostic_ref]
  defstruct [:stage, :code, :retry, :message, :diagnostic_ref]

  @stages ~w(node allocate initialize resolve prepare install start retire release_environment remove_data release_allocation inspect)a

  @type stage ::
          :node
          | :allocate
          | :initialize
          | :resolve
          | :prepare
          | :install
          | :start
          | :retire
          | :release_environment
          | :remove_data
          | :release_allocation
          | :inspect

  @codes ~w(node_abandoned resource_unavailable invalid_source resolution_failed preparation_failed installation_failed invalid_configuration container_failed lost_data ownership_mismatch inspection_failed)a

  @type code ::
          :node_abandoned
          | :resource_unavailable
          | :invalid_source
          | :resolution_failed
          | :preparation_failed
          | :installation_failed
          | :invalid_configuration
          | :container_failed
          | :lost_data
          | :ownership_mismatch
          | :inspection_failed

  @retries ~w(automatic after_change operator)a

  @type retry_policy :: :automatic | :after_change | :operator
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

  @doc "The lifecycle stage one encoded stage name describes."
  @spec parse_stage(term()) :: {:ok, stage()} | {:error, :invalid_format}
  def parse_stage(value), do: parse_enum(value, @stages)

  @spec parse(term()) :: {:ok, t()} | {:error, atom()}
  def parse(value) when is_map(value) do
    with {:ok, value} <- StrictMap.fetch_exact(value, @fields),
         {:ok, stage} <- Map.fetch(value, "stage"),
         {:ok, stage} <- parse_stage(stage),
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
