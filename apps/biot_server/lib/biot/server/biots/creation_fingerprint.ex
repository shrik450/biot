defmodule Biot.Server.Biots.CreationFingerprint do
  @moduledoc "Computes the secret-free identity of a biot creation request."

  alias Biot.Protocol.Digest
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.RelativeDirectory
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector
  alias Biot.Server.Biots.Create

  @spec compute(Create.t()) :: Digest.t()
  def compute(%Create{} = command) do
    Digest.compute(:biot_creation_v2, [
      encode_field(command.name),
      encode_field(RepositorySource.to_string(command.repository)),
      encode_environment(command.environment),
      encode_node(command.node_id),
      encode_initial_state(command.initial_state)
    ])
  end

  defp encode_environment(%EnvironmentSelection{} = selection) do
    [
      encode_field(SourceSelector.to_string(selection.base_nixpkgs)),
      <<length(selection.layers)::unsigned-big-32>>,
      Enum.map(selection.layers, &(SourceSelector.to_string(&1) |> encode_field())),
      encode_project_context(selection.project_context)
    ]
  end

  defp encode_project_context(nil), do: <<0>>

  defp encode_project_context(directory),
    do: [<<1>>, encode_field(RelativeDirectory.to_string(directory))]

  defp encode_node(:default), do: <<0>>
  defp encode_node(node_id), do: [<<1>>, encode_field(NodeId.to_string(node_id))]

  defp encode_initial_state(:running), do: <<0>>
  defp encode_initial_state(:stopped), do: <<1>>

  defp encode_field(value), do: [<<byte_size(value)::unsigned-big-32>>, value]
end
