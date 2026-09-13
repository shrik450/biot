defmodule Biot.Server.Access.Owners do
  @moduledoc """
  Owns the duplicate-key Registry for managed-access session owners.

  A process holds at most one admission at a time, so the keys it holds here are the only record
  of which closures reach it. Closure keys hold no value. An admitted owner also holds the private
  `{:admitted, stream_id}` key; its value is the monitor and timer the owner cancels when it
  closes.
  """

  alias Biot.Protocol.{BiotId, PrincipalId, StreamId}
  alias Biot.Server.Authentication.Validity

  @registry __MODULE__.Registry

  defmodule Admitted do
    @moduledoc "The control-connection monitor and expiry timer an admitted owner cancels."
    @enforce_keys [:connection_monitor, :expiry_timer]
    defstruct @enforce_keys

    @type t :: %__MODULE__{connection_monitor: reference(), expiry_timer: reference() | nil}
  end

  @type closure_key ::
          {:biot, BiotId.t()}
          | {:principal, PrincipalId.t()}
          | Validity.proof_key()

  @typep admitted_key :: {:admitted, StreamId.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: Registry.start_link(keys: :duplicate, name: @registry)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_options), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "Registers the calling process for closure by its Biot, its principal, and each proof key."
  @spec register(BiotId.t(), PrincipalId.t(), [Validity.proof_key(), ...]) :: :ok
  def register(%BiotId{} = biot_id, %PrincipalId{} = principal_id, [_ | _] = proof_keys) do
    # `unregister/0` removes every key this process holds, so a second admission in the same
    # process would lose its registrations when the first one closed.
    [] = Registry.keys(@registry, self())

    Enum.each([{:biot, biot_id}, {:principal, principal_id} | proof_keys], fn key ->
      {:ok, _owner} = Registry.register(@registry, key, nil)
    end)
  end

  @doc "Marks the calling process admitted for one stream."
  @spec admit(StreamId.t(), Admitted.t()) :: :ok
  def admit(%StreamId{} = stream_id, %Admitted{} = admitted) do
    {:ok, _owner} = Registry.register(@registry, admitted_key(stream_id), admitted)
    :ok
  end

  @spec admitted_key(StreamId.t()) :: admitted_key()
  defp admitted_key(stream_id), do: {:admitted, stream_id}

  @doc "Removes every key the calling process holds and returns the admission it must cancel."
  @spec unregister() :: [Admitted.t()]
  def unregister do
    keys = Registry.keys(@registry, self())

    admitted =
      for {:admitted, _stream_id} = key <- keys,
          value <- Registry.values(@registry, key, self()),
          do: value

    Enum.each(keys, &Registry.unregister(@registry, &1))
    admitted
  end

  @doc "Returns each distinct proof key that at least one owner holds."
  @spec proof_keys() :: [Validity.proof_key()]
  def proof_keys do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&Validity.proof_key?/1)
    |> Enum.uniq()
  end

  @spec close(closure_key()) :: :ok
  def close(key) do
    Registry.dispatch(@registry, key, fn entries ->
      Enum.each(entries, fn {pid, _value} -> send(pid, {:biot_access, :close}) end)
    end)

    :ok
  end

  @spec close_biot(BiotId.t()) :: :ok
  def close_biot(%BiotId{} = biot_id), do: close({:biot, biot_id})

  @spec close_proof(Validity.proof_key()) :: :ok
  def close_proof(proof_key), do: close(proof_key)
end
