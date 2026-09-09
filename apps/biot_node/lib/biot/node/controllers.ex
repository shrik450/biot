defmodule Biot.Node.Controllers do
  @moduledoc """
  Starts, finds, and pokes the one controller that owns each biot on this node.

  Durable intent decides which controllers exist. The control connection announces a new or changed
  intent here, `Biot.Node.Controllers.Starter` starts one controller per journal intent when the
  node boots, and a controller whose intent is gone stops itself. The registry keys controllers by
  `BiotId`, an opaque value rather than an atom, so an identifier from the wire never creates a
  name.

  The tree is `rest_for_one`: the registry comes first, the dynamic supervisor next, and the starter
  last. Losing the registry therefore restarts the starter too, and it builds the controllers again
  from the journal rather than leaving them nameless.
  """

  use Supervisor

  alias Biot.Node.BiotController
  alias Biot.Node.Controllers.Starter
  alias Biot.Protocol.BiotId

  @registry __MODULE__.Registry
  @controllers __MODULE__.Running

  @typedoc "Which biot has no controller, and why it would not start."
  @type start_error :: {:error, {BiotId.t(), term()}}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_options \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @controllers, strategy: :one_for_one},
      Starter
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "The registered name of one biot's controller."
  @spec name(BiotId.t()) :: GenServer.name()
  def name(%BiotId{} = biot_id), do: {:via, Registry, {@registry, biot_id}}

  @doc """
  Starts the controller for a biot with durable intent, or pokes the one already running. A biot
  whose controller would not start is left with the starter, which tries again.
  """
  @spec intent_changed(BiotId.t()) :: :ok | start_error()
  def intent_changed(%BiotId{} = biot_id) do
    case DynamicSupervisor.start_child(@controllers, {BiotController, biot_id: biot_id}) do
      {:ok, _pid} ->
        :ok

      # The biot has no local intent, so this node owns nothing for it.
      :ignore ->
        :ok

      {:error, {:already_started, pid}} ->
        BiotController.intent_changed(pid)

      {:error, reason} ->
        Starter.retry(biot_id)
        {:error, {biot_id, reason}}
    end
  end

  @doc """
  Announces a complete intent set: every biot in it gets a controller, and every controller left
  over is poked so it reports again or stops when its intent is gone. Every biot is tried, and the
  first one without a controller is the answer.
  """
  @spec synchronized([BiotId.t()]) :: :ok | start_error()
  def synchronized(biot_ids) do
    announced = MapSet.new(biot_ids)

    Enum.each(running(), fn {biot_id, controller} ->
      unless MapSet.member?(announced, biot_id), do: BiotController.intent_changed(controller)
    end)

    biot_ids
    |> Enum.map(&intent_changed/1)
    |> Enum.find(:ok, &match?({:error, _biot}, &1))
  end

  @doc "Every controller running right now, with the biot it owns."
  @spec running() :: [{BiotId.t(), pid()}]
  def running do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
