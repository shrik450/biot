defmodule Biot.Node.Host.ContainerInspection do
  @moduledoc "Parses Podman JSON once into the container resource reconciliation reads."

  alias Biot.Node.Host.Names
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.IncarnationId

  @type container :: Biot.Node.NodeState.container()

  @spec parse(term()) :: {:ok, container()} | {:error, :invalid_format}
  def parse(%{"Id" => id, "Config" => %{"Labels" => labels}, "State" => state})
      when is_map(labels) and is_map(state) do
    with {:ok, biot_id} <- Names.owner(labels),
         {:ok, incarnation_id} <- IncarnationId.parse(id),
         {:ok, environment_id} <-
           parse_label(labels, Names.environment_label(), EnvironmentId),
         {:ok, container_state} <- parse_state(state) do
      {:ok,
       %{
         biot_id: biot_id,
         incarnation_id: incarnation_id,
         environment_id: environment_id,
         state: container_state
       }}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  defp parse_label(labels, key, module) do
    with {:ok, value} <- Map.fetch(labels, key), do: module.parse(value)
  end

  defp parse_state(%{"Running" => true}), do: {:ok, :running}

  defp parse_state(%{"Running" => false, "ExitCode" => status})
       when is_integer(status) and status >= 0,
       do: {:ok, {:exited, status}}

  defp parse_state(_value), do: {:error, :invalid_format}
end
