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
  alias Biot.Node.SecretRequest
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.SecretOutcome

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

  @doc """
  Tells the controller that owns `biot_id` that one of its containers stopped. A biot with no
  controller here has nothing to wake: the event is a hint, and only inspection decides what is
  true.
  """
  @spec container_exited(BiotId.t()) :: :ok
  def container_exited(%BiotId{} = biot_id) do
    case Registry.lookup(@registry, biot_id) do
      [{controller, _value}] -> BiotController.container_exited(controller)
      [] -> :ok
    end
  end

  @doc """
  Hands one secret or fetch credential request to the controller that owns `biot_id`.

  A biot with no controller here has no allocation this node would serve, and saying so is the
  answer: a request must never start a controller, because starting one is how this node takes up
  intent, and a request is not intent.
  """
  @spec secret_request(BiotId.t(), SecretRequest.t()) :: :ok | SecretOutcome.t()
  def secret_request(%BiotId{} = biot_id, %SecretRequest{} = request) do
    case Registry.lookup(@registry, biot_id) do
      [{controller, _value}] -> BiotController.secret_request(controller, request)
      [] -> :no_allocation
    end
  end

  @doc "Every controller running right now, with the biot it owns."
  @spec running() :: [{BiotId.t(), pid()}]
  def running do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
