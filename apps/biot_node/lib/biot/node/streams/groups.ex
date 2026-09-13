defmodule Biot.Node.Streams.Groups do
  @moduledoc """
  The pure decision core for the node stream boundary.

  One group exists per biot, current control connection, and applied access revision. Revision
  application and admission both decide here, so an admission that would join a closing, obsolete,
  or future group is refused instead of raced.

  A group's child PIDs are its only membership record; their count is its size. Closing a group
  returns the PIDs to terminate, and this module never starts or stops a process.
  """

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.StreamFailure

  defstruct groups: %{}

  @type group :: %{
          connection_id: ConnectionId.t(),
          revision: pos_integer(),
          children: MapSet.t(pid())
        }
  @type t :: %__MODULE__{groups: %{BiotId.t() => group()}}
  @type limits :: %{total: pos_integer(), per_biot: pos_integer()}
  @type effect :: {:terminate, [pid()]}
  @type revision_result :: {:applied, t(), [effect()]} | {:ignored, t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec apply_revision(t(), BiotId.t(), ConnectionId.t(), pos_integer()) :: revision_result()
  def apply_revision(
        %__MODULE__{} = state,
        %BiotId{} = biot_id,
        %ConnectionId{} = connection_id,
        revision
      ) do
    case Map.get(state.groups, biot_id) do
      %{connection_id: ^connection_id, revision: ^revision} ->
        {:applied, state, []}

      %{revision: applied} when revision < applied ->
        {:ignored, state}

      existing ->
        group = %{connection_id: connection_id, revision: revision, children: MapSet.new()}
        {:applied, put_group(state, biot_id, group), terminate_effect(children_of(existing))}
    end
  end

  @spec admit(t(), limits(), BiotId.t(), ConnectionId.t(), pos_integer()) ::
          :ok | {:refuse, StreamFailure.t()}
  def admit(
        %__MODULE__{} = state,
        limits,
        %BiotId{} = biot_id,
        %ConnectionId{} = connection_id,
        revision
      ) do
    with {:ok, group} <- fetch_group(state, biot_id),
         :ok <- current?(group, connection_id, revision) do
      room?(state, group, limits)
    end
  end

  @spec put_child(t(), BiotId.t(), pid()) :: t()
  def put_child(%__MODULE__{} = state, %BiotId{} = biot_id, pid) when is_pid(pid) do
    group = Map.fetch!(state.groups, biot_id)
    put_group(state, biot_id, %{group | children: MapSet.put(group.children, pid)})
  end

  @spec child_down(t(), pid()) :: t()
  def child_down(%__MODULE__{} = state, pid) when is_pid(pid) do
    {biot_id, group} =
      Enum.find(state.groups, fn {_biot_id, group} -> MapSet.member?(group.children, pid) end)

    put_group(state, biot_id, %{group | children: MapSet.delete(group.children, pid)})
  end

  @spec close_all(t()) :: {t(), [effect()]}
  def close_all(%__MODULE__{} = state) do
    pids = state.groups |> Map.values() |> Enum.flat_map(&MapSet.to_list(&1.children))
    {%__MODULE__{groups: %{}}, terminate_effect(pids)}
  end

  defp fetch_group(state, biot_id) do
    case Map.get(state.groups, biot_id) do
      nil -> {:refuse, :unknown_biot}
      group -> {:ok, group}
    end
  end

  defp current?(%{connection_id: connection_id, revision: revision}, connection_id, revision),
    do: :ok

  defp current?(_group, _connection_id, _revision), do: {:refuse, :stale_access}

  defp room?(state, group, limits) do
    total = state.groups |> Map.values() |> Enum.map(&MapSet.size(&1.children)) |> Enum.sum()

    if total >= limits.total or MapSet.size(group.children) >= limits.per_biot,
      do: {:refuse, :too_many_streams},
      else: :ok
  end

  defp put_group(state, biot_id, group) do
    %{state | groups: Map.put(state.groups, biot_id, group)}
  end

  defp children_of(nil), do: []
  defp children_of(group), do: MapSet.to_list(group.children)

  defp terminate_effect([]), do: []
  defp terminate_effect(pids), do: [{:terminate, pids}]
end
