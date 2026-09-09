defmodule Biot.Server.Nodes.Registration do
  @moduledoc "A parsed operator request that binds a node to one registration and certificate identity."

  alias Biot.Protocol.NodeId
  alias Biot.Protocol.RegistrationId
  alias Biot.Server.Nodes.Status

  @enforce_keys [:node_id, :registration_id, :peer_identity, :max_biots, :status]
  defstruct [:node_id, :registration_id, :peer_identity, :max_biots, :status]

  @type status :: Status.t()
  @type t :: %__MODULE__{
          node_id: NodeId.t(),
          registration_id: RegistrationId.t(),
          peer_identity: String.t(),
          max_biots: pos_integer(),
          status: status()
        }

  @doc "Parses a map whose peer identity is the lowercase SHA-256 fingerprint of the certificate public key."
  @spec parse(term()) :: {:ok, t()} | {:error, {atom(), atom()}}
  def parse(value) when is_map(value) do
    with {:ok, node_id} <- fetch(value, :node_id),
         {:ok, node_id} <- parse_value(NodeId, :node_id, node_id),
         {:ok, registration_id} <- fetch(value, :registration_id),
         {:ok, registration_id} <-
           parse_value(RegistrationId, :registration_id, registration_id),
         {:ok, peer_identity} <- fetch(value, :peer_identity),
         {:ok, peer_identity} <- parse_peer_identity(peer_identity),
         {:ok, max_biots} <- fetch(value, :max_biots),
         {:ok, max_biots} <- parse_max_biots(max_biots),
         {:ok, status} <- fetch(value, :status),
         {:ok, status} <- parse_status(status) do
      {:ok,
       %__MODULE__{
         node_id: node_id,
         registration_id: registration_id,
         peer_identity: peer_identity,
         max_biots: max_biots,
         status: status
       }}
    end
  end

  def parse(_value), do: {:error, {:registration, :invalid_format}}

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> map |> Map.fetch(Atom.to_string(key)) |> missing(key)
    end
  end

  defp missing(:error, key), do: {:error, {key, :missing}}
  defp missing({:ok, value}, _key), do: {:ok, value}

  defp parse_value(module, field, value) do
    case module.parse(value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {field, reason}}
    end
  end

  defp parse_peer_identity(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value) do
      {:ok, value}
    else
      {:error, {:peer_identity, :invalid_format}}
    end
  end

  defp parse_peer_identity(_value), do: {:error, {:peer_identity, :invalid_format}}

  defp parse_max_biots(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_max_biots(_value), do: {:error, {:max_biots, :not_positive}}

  defp parse_status(status) when status in [:enabled, :disabled, :retired, :abandoned],
    do: {:ok, status}

  defp parse_status("enabled"), do: {:ok, :enabled}
  defp parse_status("disabled"), do: {:ok, :disabled}
  defp parse_status("retired"), do: {:ok, :retired}
  defp parse_status("abandoned"), do: {:ok, :abandoned}
  defp parse_status(_status), do: {:error, {:status, :invalid_value}}
end
