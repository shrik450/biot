defmodule Biot.Server.Access.Admission do
  @moduledoc """
  Runs the session-owner protocol around a proof-and-policy snapshot.

  The owner registers before it reads the snapshot, so a withdrawal that commits later finds it.
  A close that arrives while the owner checks, opens, or holds the stream closes the stream and
  removes every registration. The struct is what one snapshot allows the owner to open, and until
  when.
  """

  alias Biot.Protocol.{BiotId, NodeId, StreamTarget}
  alias Biot.Server.Access.Owners
  alias Biot.Server.Access.Owners.Admitted
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.Authentication.Validity
  alias Biot.Server.Repo
  alias Biot.Server.Streams
  alias Biot.Server.Streams.Stream

  @enforce_keys [:node_id, :access_revision, :target, :expires_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          node_id: NodeId.t(),
          access_revision: pos_integer(),
          target: StreamTarget.t(),
          expires_at: DateTime.t() | nil
        }

  @type error ::
          :unauthenticated
          | :not_found
          | :forbidden
          | :node_unavailable
          | :agent_unreachable
          | :port_not_listening
          | :too_many_streams
          | :timeout

  @type owner_reason :: :policy | :control_lost | :expired | :closed

  @type snapshot ::
          (Ecto.Repo.t() | module(), DateTime.t() -> {:ok, t()} | {:error, error()})

  @doc """
  Admits the calling process as the owner of one stream on `biot_id`.

  Each proof-and-policy read runs `snapshot` in one transaction. A `stale_access` open reads it
  once more within the same deadline.
  """
  @spec admit(Authentication.t(), BiotId.t(), snapshot()) ::
          {:ok, Stream.t()} | {:error, error()}
  def admit(
        %Authentication{actor: %Actor{principal_id: principal_id}} = authentication,
        %BiotId{} = biot_id,
        snapshot
      ) do
    deadline = System.monotonic_time(:millisecond) + stream_timeout_ms()

    # Before registration no closer can find this process, so a close already in the mailbox
    # belongs to an earlier admission.
    :ok = drain_closes()
    :ok = Owners.register(biot_id, principal_id, Validity.proof_keys(authentication))

    case admit_registered(biot_id, deadline, snapshot, true) do
      {:ok, %Stream{}} = admitted ->
        admitted

      {:error, _reason} = error ->
        # A raced close has already unregistered and cancelled its admission.
        [] = Owners.unregister()
        error
    end
  end

  @doc "Handles a policy close, control-process loss, or absolute-expiry message for an owner."
  @spec handle_owner_message(Stream.t(), term()) :: {:closed, owner_reason()} | :ignored
  def handle_owner_message(
        %Stream{connection_pid: connection_pid} = stream,
        {:DOWN, _reference, :process, connection_pid, _reason}
      ),
      do: close_owner(stream, :control_lost)

  def handle_owner_message(%Stream{id: stream_id} = stream, {:biot_access, :expired, stream_id}),
    do: close_owner(stream, :expired)

  def handle_owner_message(%Stream{} = stream, {:biot_access, :close}),
    do: close_owner(stream, :policy)

  def handle_owner_message(%Stream{}, _message), do: :ignored

  @doc """
  Closes an admitted stream and removes its owner registrations.

  This is the only close an owner may use. `Streams.close/1` leaves the owner registered, so the
  next admission in the same process would crash in `Owners.register/3`.
  """
  @spec close(Stream.t()) :: :ok
  def close(%Stream{} = stream) do
    Enum.each(Owners.unregister(), &cancel_admitted/1)
    Streams.close(stream)
  end

  @doc "Closes the owners of every registered proof that is no longer valid."
  @spec close_invalid_proof_owners() :: :ok
  def close_invalid_proof_owners do
    now = DateTime.utc_now()

    Owners.proof_keys()
    |> Enum.reject(&Validity.key_valid?(Repo, &1, now))
    |> Enum.each(&Owners.close_proof/1)
  end

  defp admit_registered(biot_id, deadline, snapshot, retry?) do
    with :ok <- no_close(),
         {:ok, %__MODULE__{} = admission} <- read_snapshot(snapshot),
         :ok <- no_close() do
      case Streams.open_until(
             admission.node_id,
             biot_id,
             admission.access_revision,
             admission.target,
             deadline
           ) do
        {:ok, %Stream{} = stream} ->
          mark_admitted(stream, admission.expires_at)

        {:error, :stale_access} when retry? ->
          admit_registered(biot_id, deadline, snapshot, false)

        {:error, :stale_access} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, open_error(reason)}
      end
    end
  end

  defp mark_admitted(%Stream{id: stream_id, connection_pid: connection_pid} = stream, expires_at) do
    :ok =
      Owners.admit(stream_id, %Admitted{
        connection_monitor: Process.monitor(connection_pid),
        expiry_timer: expiry_timer(stream_id, expires_at)
      })

    case no_close() do
      :ok ->
        {:ok, stream}

      {:error, :forbidden} = denied ->
        close(stream)
        denied
    end
  end

  defp read_snapshot(snapshot) do
    Repo.transact(fn repo -> snapshot.(repo, DateTime.utc_now()) end)
  end

  defp expiry_timer(_stream_id, nil), do: nil

  defp expiry_timer(stream_id, %DateTime{} = expires_at) do
    delay = max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), {:biot_access, :expired, stream_id}, delay)
  end

  defp close_owner(stream, reason) do
    close(stream)
    {:closed, reason}
  end

  defp cancel_admitted(%Admitted{connection_monitor: monitor, expiry_timer: timer}) do
    Process.demonitor(monitor, [:flush])
    cancel_timer(timer)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: _ = Process.cancel_timer(timer)

  defp no_close do
    receive do
      {:biot_access, :close} -> {:error, :forbidden}
    after
      0 -> :ok
    end
  end

  defp drain_closes do
    receive do
      {:biot_access, :close} -> drain_closes()
    after
      0 -> :ok
    end
  end

  defp stream_timeout_ms, do: Application.fetch_env!(:biot_server, :stream_open_timeout_ms)

  defp open_error(:unknown_biot), do: :not_found
  defp open_error(reason), do: reason
end
