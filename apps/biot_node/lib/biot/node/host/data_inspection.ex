defmodule Biot.Node.Host.DataInspection do
  @moduledoc """
  Derives one allocation's data state from journal and host facts.

  The completion marker holds the biot that owns the data. A marker naming another biot is lost
  data, never permission to adopt what it names.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Outcome
  alias Biot.Node.NodeState
  alias Biot.Protocol.BiotId

  @type facts :: %{
          allocation_directory: FileSystem.fact(:directory),
          mounts: [FileSystem.fact(:directory)],
          marker: FileSystem.fact(binary())
        }

  @spec state(Allocation.t(), facts()) :: NodeState.data_state()
  def state(%Allocation{initialization: :uninitialized} = allocation, facts) do
    case facts.allocation_directory do
      {:error, reason} ->
        unknown(allocation, reason, "the allocation directory could not be inspected")

      _directory ->
        {:uninitialized, allocation}
    end
  end

  def state(%Allocation{initialization: :complete} = allocation, facts) do
    case facts.allocation_directory do
      {:error, reason} ->
        unknown(allocation, reason, "the allocation directory could not be inspected")

      _directory ->
        initialized_state(allocation, facts.mounts, facts.marker)
    end
  end

  defp initialized_state(allocation, mounts, {:present, marker_text}) do
    cond do
      Enum.any?(mounts, &match?({:error, _reason}, &1)) ->
        mount_error(allocation, mounts)

      Enum.all?(mounts, &match?({:present, :directory}, &1)) ->
        marker_state(allocation, marker_text)

      true ->
        {:lost, allocation}
    end
  end

  defp initialized_state(allocation, mounts, :absent) do
    if Enum.any?(mounts, &match?({:error, _reason}, &1)),
      do: mount_error(allocation, mounts),
      else: {:lost, allocation}
  end

  defp initialized_state(allocation, _mounts, {:error, reason}) do
    unknown(allocation, reason, "the initialization marker could not be read")
  end

  defp marker_state(%Allocation{biot_id: biot_id} = allocation, marker_text) do
    case BiotId.parse(String.trim(marker_text)) do
      {:ok, ^biot_id} -> {:present, allocation}
      {:ok, _other_biot_id} -> {:lost, allocation}
      {:error, _reason} -> {:lost, allocation}
    end
  end

  defp mount_error(allocation, mounts) do
    {:error, reason} = Enum.find(mounts, &match?({:error, _reason}, &1))
    unknown(allocation, reason, "a private mount could not be inspected")
  end

  defp unknown(allocation, reason, detail) do
    {:unknown, allocation, Outcome.inspection(:data, reason, detail)}
  end
end
