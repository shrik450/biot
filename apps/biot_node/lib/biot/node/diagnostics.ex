defmodule Biot.Node.Diagnostics do
  @moduledoc "Holds a bounded set of node diagnostics for on-demand control requests."

  use GenServer

  alias Biot.Protocol.PrivateDiagnosticId

  defmodule State do
    @moduledoc false
    defstruct entries: %{}, order: [], max_entries: 100, max_entry_bytes: 1_000_000
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, Keyword.delete(options, :name), name: __MODULE__)
  end

  @spec put(PrivateDiagnosticId.t(), binary()) :: :ok
  def put(%PrivateDiagnosticId{} = diagnostic_id, content) when is_binary(content) do
    GenServer.call(__MODULE__, {:put, diagnostic_id, content})
  end

  @spec fetch(PrivateDiagnosticId.t(), pos_integer()) ::
          {:ok, {binary(), boolean()}} | :not_found
  def fetch(%PrivateDiagnosticId{} = diagnostic_id, max_bytes) when max_bytes > 0 do
    GenServer.call(__MODULE__, {:fetch, diagnostic_id, max_bytes})
  end

  @impl true
  def init(options) do
    {:ok,
     %State{
       max_entries:
         Keyword.get(
           options,
           :max_entries,
           Application.get_env(:biot_node, :diagnostic_max_entries, 100)
         ),
       max_entry_bytes:
         Keyword.get(
           options,
           :max_entry_bytes,
           Application.get_env(:biot_node, :diagnostic_max_entry_bytes, 1_000_000)
         )
     }}
  end

  @impl true
  def handle_call({:put, diagnostic_id, content}, _from, state) do
    {stored, truncated} = truncate(content, state.max_entry_bytes)
    entries = Map.put(state.entries, diagnostic_id, {stored, truncated})
    order = [diagnostic_id | Enum.reject(state.order, &(&1 == diagnostic_id))]
    {entries, order} = evict(entries, order, state.max_entries)
    {:reply, :ok, %{state | entries: entries, order: order}}
  end

  def handle_call({:fetch, diagnostic_id, max_bytes}, _from, state) do
    result =
      case Map.get(state.entries, diagnostic_id) do
        nil ->
          :not_found

        {content, storage_truncated} ->
          {content, request_truncated} = truncate(content, max_bytes)
          {:ok, {content, storage_truncated or request_truncated}}
      end

    {:reply, result, state}
  end

  defp truncate(content, max_bytes) when byte_size(content) > max_bytes do
    {binary_part(content, 0, max_bytes), true}
  end

  defp truncate(content, _max_bytes), do: {content, false}

  defp evict(entries, order, max_entries) do
    {keep, remove} = Enum.split(order, max_entries)
    {Map.drop(entries, remove), keep}
  end
end
