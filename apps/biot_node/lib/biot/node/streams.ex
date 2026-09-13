defmodule Biot.Node.Streams do
  @moduledoc """
  Owns the node's stream groups and serializes revision changes with admission.

  The server reads policy and asks for a stream; this boundary is the only place that decides
  whether the node can accept it. It holds one group per biot, current control connection, and
  applied access revision. Applying a revision closes the old group and waits for every child to
  exit before the control connection acknowledges, so `access_applied` never arrives while a
  stream under the old revision is still running.

  Admission is a call into this process, so a child cannot join a group that is closing. The
  boundary deliberately does not read the journal: a group exists exactly while a spec for that
  biot is applied, and a synchronization omission removes it, so the absence of a group is what
  `unknown_biot` means. Children live under one `DynamicSupervisor`; `Groups` holds their only
  membership record.
  """

  use GenServer

  alias Biot.Node.Streams.Groups
  alias Biot.Node.Streams.Stream
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.StreamFailure
  alias Biot.Protocol.StreamId
  alias Biot.Protocol.StreamTarget

  defmodule State do
    @moduledoc false
    defstruct [:groups, :limits, monitors: %{}]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @spec apply_revision(BiotId.t(), ConnectionId.t(), pos_integer()) :: :applied | :ignored
  def apply_revision(%BiotId{} = biot_id, %ConnectionId{} = connection_id, revision) do
    GenServer.call(__MODULE__, {:apply_revision, biot_id, connection_id, revision})
  end

  @spec admit(
          BiotId.t(),
          ConnectionId.t(),
          pos_integer(),
          StreamId.t(),
          StreamTarget.t(),
          Stream.dial_options()
        ) :: :ok | {:error, StreamFailure.t()}
  def admit(
        %BiotId{} = biot_id,
        %ConnectionId{} = connection_id,
        revision,
        %StreamId{} = stream_id,
        target,
        dial_options
      ) do
    GenServer.call(
      __MODULE__,
      {:admit, biot_id, connection_id, revision, stream_id, target, dial_options}
    )
  end

  @spec close_all() :: :ok
  def close_all, do: GenServer.call(__MODULE__, :close_all)

  @impl true
  def init(options) do
    limits = %{
      total: option(options, :max_streams),
      per_biot: option(options, :max_streams_per_biot)
    }

    {:ok, %State{groups: Groups.new(), limits: limits}}
  end

  @impl true
  def handle_call({:apply_revision, biot_id, connection_id, revision}, _from, state) do
    case Groups.apply_revision(state.groups, biot_id, connection_id, revision) do
      {:applied, groups, effects} ->
        {:reply, :applied, run(%{state | groups: groups}, effects)}

      {:ignored, groups} ->
        {:reply, :ignored, %{state | groups: groups}}
    end
  end

  def handle_call(
        {:admit, biot_id, connection_id, revision, stream_id, target, dial_options},
        _from,
        state
      ) do
    case Groups.admit(state.groups, state.limits, biot_id, connection_id, revision) do
      :ok ->
        stream = %Stream{
          biot_id: biot_id,
          connection_id: connection_id,
          revision: revision,
          stream_id: stream_id,
          target: target,
          dial_options: dial_options
        }

        {:ok, pid} = DynamicSupervisor.start_child(Biot.Node.Streams.Children, {Stream, stream})
        monitors = Map.put(state.monitors, pid, Process.monitor(pid))
        groups = Groups.put_child(state.groups, biot_id, pid)
        {:reply, :ok, %{state | groups: groups, monitors: monitors}}

      {:refuse, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close_all, _from, state) do
    {groups, effects} = Groups.close_all(state.groups)
    {:reply, :ok, run(%{state | groups: groups}, effects)}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    {^reference, monitors} = Map.pop(state.monitors, pid)
    {:noreply, %{state | groups: Groups.child_down(state.groups, pid), monitors: monitors}}
  end

  defp run(state, effects), do: Enum.reduce(effects, state, &run_effect/2)

  defp run_effect({:terminate, pids}, state), do: Enum.reduce(pids, state, &terminate_child/2)

  defp terminate_child(pid, state) do
    {reference, monitors} = Map.pop(state.monitors, pid)
    Process.demonitor(reference, [:flush])

    # A child that already stopped by itself can leave the supervisor before its DOWN reaches us,
    # so the child is then already gone and there is nothing left to terminate.
    case DynamicSupervisor.terminate_child(Biot.Node.Streams.Children, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    %{state | monitors: monitors}
  end

  defp option(options, key) do
    Keyword.get(options, key, Application.fetch_env!(:biot_node, key))
  end
end
