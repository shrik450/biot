defmodule Biot.Node.Host.Names do
  @moduledoc "Owns Podman network names, container names, and ownership labels."

  alias Biot.Node.NetworkId
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.IncarnationId

  @biot_label "io.biot.biot-id"
  @incarnation_label "io.biot.incarnation-id"
  @environment_label "io.biot.environment-id"

  @spec network(NetworkId.t()) :: String.t()
  def network(network_id), do: "biot-network-" <> NetworkId.to_string(network_id)

  @spec container(IncarnationId.t()) :: String.t()
  def container(incarnation_id), do: "biot-" <> IncarnationId.to_string(incarnation_id)

  @spec label_arguments(BiotId.t(), IncarnationId.t(), EnvironmentId.t()) :: [String.t()]
  def label_arguments(biot_id, incarnation_id, environment_id) do
    %{
      @biot_label => BiotId.to_string(biot_id),
      @incarnation_label => IncarnationId.to_string(incarnation_id),
      @environment_label => EnvironmentId.to_string(environment_id)
    }
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} -> ["--label", "#{key}=#{value}"] end)
  end

  @spec biot_label() :: String.t()
  def biot_label, do: @biot_label

  @spec incarnation_label() :: String.t()
  def incarnation_label, do: @incarnation_label

  @spec environment_label() :: String.t()
  def environment_label, do: @environment_label
end
