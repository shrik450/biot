defmodule Biot.Node.Host.DataInspection do
  @moduledoc "Derives one allocation's data state from journal and host facts."

  alias Biot.Node.Allocation
  alias Biot.Node.Host.Outcome
  alias Biot.Node.MarkerId
  alias Biot.Node.NodeState

  @type facts :: %{
          allocation_directory: Biot.Node.Host.FileSystem.fact(:directory),
          mounts: [Biot.Node.Host.FileSystem.fact(:directory)],
          marker: Biot.Node.Host.FileSystem.fact(binary())
        }

  @spec state(Allocation.t(), facts()) :: NodeState.data_state()
  def state(%Allocation{initialization: :uninitialized} = allocation, facts) do
    case facts.allocation_directory do
      {:error, reason} ->
        unknown(allocation, :data, reason, "the allocation directory could not be inspected")

      _directory ->
        {:uninitialized, allocation}
    end
  end

  def state(
        %Allocation{initialization: {:complete, expected_marker}} = allocation,
        facts
      ) do
    case facts.allocation_directory do
      {:error, reason} ->
        unknown(allocation, :data, reason, "the allocation directory could not be inspected")

      _directory ->
        initialized_state(allocation, expected_marker, facts.mounts, facts.marker)
    end
  end

  defp initialized_state(allocation, expected_marker, mounts, {:present, marker_text}) do
    cond do
      Enum.any?(mounts, &match?({:error, _reason}, &1)) ->
        mount_error(allocation, mounts)

      Enum.all?(mounts, &match?({:present, :directory}, &1)) ->
        marker_state(allocation, expected_marker, marker_text)

      true ->
        {:lost, allocation}
    end
  end

  defp initialized_state(allocation, _expected_marker, mounts, :absent) do
    if Enum.any?(mounts, &match?({:error, _reason}, &1)),
      do: mount_error(allocation, mounts),
      else: {:lost, allocation}
  end

  defp initialized_state(allocation, _expected_marker, _mounts, {:error, reason}) do
    unknown(allocation, :data, reason, "the initialization marker could not be read")
  end

  defp marker_state(allocation, expected_marker, marker_text) do
    case MarkerId.parse(String.trim(marker_text)) do
      {:ok, ^expected_marker} -> {:present, allocation, expected_marker}
      {:ok, _other_marker} -> {:lost, allocation}
      {:error, _reason} -> {:lost, allocation}
    end
  end

  defp mount_error(allocation, mounts) do
    {:error, reason} = Enum.find(mounts, &match?({:error, _reason}, &1))
    unknown(allocation, :data, reason, "a private mount could not be inspected")
  end

  defp unknown(allocation, resource, reason, detail) do
    {:unknown, allocation, Outcome.inspection(resource, reason, detail)}
  end
end
