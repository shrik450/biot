defmodule Biot.Node.Intents do
  @moduledoc "Holds the latest synchronized BiotSpec values and publishes changes. Step 9 replaces this state with durable LocalIntent persistence."

  use GenServer

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec put(BiotSpec.t()) :: :ok
  def put(%BiotSpec{} = spec), do: GenServer.call(__MODULE__, {:put, spec})

  @spec get(BiotId.t()) :: BiotSpec.t() | nil
  def get(%BiotId{} = biot_id) do
    case :ets.lookup(__MODULE__, biot_id) do
      [{^biot_id, spec}] -> spec
      [] -> nil
    end
  end

  @spec all() :: [BiotSpec.t()]
  def all do
    __MODULE__
    |> :ets.tab2list()
    |> Enum.map(fn {_biot_id, spec} -> spec end)
  end

  @spec replace([BiotSpec.t()]) :: :ok
  def replace(specs) when is_list(specs), do: GenServer.call(__MODULE__, {:replace, specs})

  @spec subscribe(BiotId.t()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def subscribe(%BiotId{} = biot_id) do
    Registry.register(Biot.Node.Intents.Registry, biot_id, nil)
  end

  @spec subscribe_all() :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def subscribe_all do
    Registry.register(Biot.Node.Intents.Registry, :all, nil)
  end

  @impl true
  def init(:ok) do
    __MODULE__ = :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, :no_state}
  end

  @impl true
  def handle_call({:put, spec}, _from, state) do
    biot_id = spec.execution.biot_id
    current = get(biot_id)

    true = :ets.insert(__MODULE__, {biot_id, spec})

    if current != spec do
      publish(biot_id, spec)
    end

    {:reply, :ok, state}
  end

  def handle_call({:replace, specs}, _from, state) do
    replacement = Map.new(specs, &{&1.execution.biot_id, &1})
    current = Map.new(:ets.tab2list(__MODULE__))

    changed_ids =
      current
      |> Map.keys()
      |> Kernel.++(Map.keys(replacement))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(current, &1) != Map.get(replacement, &1)))

    true = :ets.delete_all_objects(__MODULE__)
    true = :ets.insert(__MODULE__, Map.to_list(replacement))
    Enum.each(changed_ids, &publish(&1, Map.get(replacement, &1)))
    {:reply, :ok, state}
  end

  defp publish(biot_id, spec) do
    Enum.each([biot_id, :all], fn key ->
      Registry.dispatch(Biot.Node.Intents.Registry, key, &notify(&1, biot_id, spec))
    end)
  end

  defp notify(entries, biot_id, spec) do
    Enum.each(entries, fn {pid, _value} -> send(pid, {:intent_changed, biot_id, spec}) end)
  end
end
