defmodule Biot.Node.Controllers.Starter do
  @moduledoc """
  Keeps the promise that every biot with durable local intent has a live controller.

  It starts one controller per journal intent when the node boots, and it stays alive so that a
  start which failed is made again after a bounded delay. It holds one pending attempt per biot, so
  repeated announcements of the same broken biot cost one timer.

  It sits last under the `rest_for_one` tree in `Biot.Node.Controllers`, so losing the registry or
  the dynamic supervisor restarts this process and the controllers are built again from the journal.
  """

  use GenServer

  require Logger

  alias Biot.Node.Controllers
  alias Biot.Node.Journal
  alias Biot.Protocol.BiotId

  defmodule State do
    @moduledoc false

    @enforce_keys [:retry_ms]
    defstruct [:retry_ms, pending: MapSet.new()]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc "Asks for another attempt at one biot whose controller would not start."
  @spec retry(BiotId.t()) :: :ok
  def retry(%BiotId{} = biot_id), do: GenServer.cast(__MODULE__, {:retry, biot_id})

  @impl true
  def init(options) do
    retry_ms =
      Keyword.get_lazy(options, :controller_start_retry_ms, fn ->
        Application.fetch_env!(:biot_node, :controller_start_retry_ms)
      end)

    {:ok, %State{retry_ms: retry_ms}, {:continue, :journal_intents}}
  end

  @impl true
  def handle_continue(:journal_intents, %State{} = state) do
    Enum.each(Journal.intents(), fn intent -> Controllers.intent_changed(intent.biot_id) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:retry, biot_id}, %State{} = state) do
    if MapSet.member?(state.pending, biot_id) do
      {:noreply, state}
    else
      Logger.error(
        "biot #{BiotId.to_string(biot_id)} has durable intent and no controller; trying again in #{state.retry_ms} ms"
      )

      Process.send_after(self(), {:start, biot_id}, state.retry_ms)
      {:noreply, %{state | pending: MapSet.put(state.pending, biot_id)}}
    end
  end

  # A failed attempt asks for the next one itself, and the cast arrives after this one is no longer
  # pending, so the delay between attempts stays bounded.
  @impl true
  def handle_info({:start, biot_id}, %State{} = state) do
    state = %{state | pending: MapSet.delete(state.pending, biot_id)}
    _result = Controllers.intent_changed(biot_id)
    {:noreply, state}
  end
end
