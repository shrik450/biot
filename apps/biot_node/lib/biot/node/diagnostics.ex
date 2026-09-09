defmodule Biot.Node.Diagnostics do
  @moduledoc """
  The node's bounded diagnostic log. For each biot revision it keeps the output of the latest
  failed attempt under a `PrivateDiagnosticId`, which the reported `Failure` carries, so an
  authorized owner can ask the server for a useful excerpt afterwards.

  One process owns the log and holds it in a protected ETS table. Writes go through the process
  because the two bounds, the bytes kept per entry and the entries kept per biot, need one writer
  to stay correct. Reads go straight to the table, so a fetch never waits behind a controller
  storing a large build log; the server fetches with a deadline and expects a bounded answer
  inside it.

  Both bounds are per biot, so one noisy biot cannot push another biot's diagnostic out of the
  log.
  """

  use GenServer

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.CanonicalUuid
  alias Biot.Protocol.PrivateDiagnosticId

  @table __MODULE__

  defmodule State do
    @moduledoc false

    @enforce_keys [:max_entry_bytes, :max_entries_per_biot]
    defstruct [:max_entry_bytes, :max_entries_per_biot, biots: %{}]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, Keyword.delete(options, :name), name: __MODULE__)
  end

  @doc "Stores the diagnostic for one biot revision and returns the id the failure reports."
  @spec put(BiotId.t(), pos_integer(), binary()) :: PrivateDiagnosticId.t()
  def put(%BiotId{} = biot_id, revision, content)
      when is_integer(revision) and revision > 0 and is_binary(content) do
    GenServer.call(__MODULE__, {:put, biot_id, revision, content})
  end

  @doc "The stored diagnostic, bounded by the caller's limit, and whether anything was cut."
  @spec fetch(PrivateDiagnosticId.t(), pos_integer()) ::
          {:ok, {binary(), boolean()}} | :not_found
  def fetch(%PrivateDiagnosticId{} = diagnostic_id, max_bytes) when max_bytes > 0 do
    case :ets.lookup(@table, diagnostic_id) do
      [{^diagnostic_id, content, stored_truncated}] ->
        {content, request_truncated} = truncate(content, max_bytes)
        {:ok, {content, stored_truncated or request_truncated}}

      [] ->
        :not_found
    end
  end

  @doc "Drops every diagnostic of a biot this node no longer owns."
  @spec forget(BiotId.t()) :: :ok
  def forget(%BiotId{} = biot_id), do: GenServer.call(__MODULE__, {:forget, biot_id})

  @impl true
  def init(options) do
    @table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    {:ok,
     %State{
       max_entry_bytes: setting(options, :diagnostic_max_entry_bytes, 65_536),
       max_entries_per_biot: setting(options, :diagnostic_max_entries_per_biot, 5)
     }}
  end

  @impl true
  def handle_call({:put, biot_id, revision, content}, _from, state) do
    diagnostic_id = mint()
    {stored, truncated} = truncate(content, state.max_entry_bytes)
    true = :ets.insert(@table, {diagnostic_id, stored, truncated})

    {replaced, older} =
      state.biots
      |> Map.get(biot_id, [])
      |> Enum.split_with(&match?({^revision, _diagnostic_id}, &1))

    {kept, evicted} =
      Enum.split([{revision, diagnostic_id} | older], state.max_entries_per_biot)

    delete(replaced ++ evicted)
    {:reply, diagnostic_id, %{state | biots: Map.put(state.biots, biot_id, kept)}}
  end

  def handle_call({:forget, biot_id}, _from, state) do
    {entries, biots} = Map.pop(state.biots, biot_id, [])
    delete(entries)
    {:reply, :ok, %{state | biots: biots}}
  end

  defp delete(entries) do
    Enum.each(entries, fn {_revision, diagnostic_id} -> :ets.delete(@table, diagnostic_id) end)
  end

  defp truncate(content, max_bytes) when byte_size(content) > max_bytes do
    {binary_part(content, 0, max_bytes), true}
  end

  defp truncate(content, _max_bytes), do: {content, false}

  defp mint do
    {:ok, diagnostic_id} = PrivateDiagnosticId.parse(CanonicalUuid.generate())
    diagnostic_id
  end

  defp setting(options, key, default) do
    Keyword.get(options, key, Application.get_env(:biot_node, key, default))
  end
end
