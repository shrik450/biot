defmodule Biot.Node.Control.Connection do
  @moduledoc """
  Owns the node TLS control connection, synchronization, heartbeats, and reconnects.

  It also owns `Biot.Node.Control.Outbox` and drains it while the link is ready, so a controller's
  report never waits for the socket.

  A finished destruction leaves its report in the journal rather than in a controller, so this
  connection replays it: once when a link becomes ready, and again each time the server repeats
  the intent for that biot.
  """

  use GenServer

  require Logger

  alias Biot.Node.Control
  alias Biot.Node.Control.Outbox
  alias Biot.Node.Control.Staging
  alias Biot.Node.Controllers
  alias Biot.Node.Diagnostics
  alias Biot.Node.Journal
  alias Biot.Node.LocalIntent
  alias Biot.Node.Orphans
  alias Biot.Node.RuntimeLogs
  alias Biot.Node.SecretRequest
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Liveness
  alias Biot.Protocol.Message
  alias Biot.Protocol.PeerIdentity
  alias Biot.Protocol.Platform
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.SecretOutcome
  alias Biot.Protocol.Version
  alias Biot.Protocol.Wire

  defmodule State do
    @moduledoc """
    Holds one control link state.

    `:disconnected` accepts reconnect timers. `:handshake` accepts `connected` or `reject`.
    `:synchronizing` accepts snapshot messages and heartbeats. A staged snapshot accepts only
    items, its matching end, and heartbeats. `:ready` accepts desired intent, diagnostics, and
    heartbeats.
    """
    defstruct [
      :max_frame_bytes,
      :max_staged_specs,
      status: :disconnected,
      socket: nil,
      buffer: <<>>,
      version: nil,
      connection_id: nil,
      staging: nil,
      heartbeat_challenge: nil,
      pending_reads: %{},
      reconnect_token: nil,
      backoff_ms: 250,
      server_host: nil,
      server_port: nil,
      server_fingerprint: nil,
      registration_id: nil,
      platform: nil,
      tls: nil,
      heartbeat_interval_ms: 30_000,
      heartbeat_timeout_ms: 10_000,
      backoff_min_ms: 250,
      backoff_max_ms: 30_000
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc "Tells the connection that the outbox holds a report it has not seen."
  @spec wake() :: :ok
  def wake, do: GenServer.cast(__MODULE__, :drain)

  @doc """
  Answers one secret or fetch credential request on the link that asked for it.

  A controller serves the request and this sends the result, so the two halves of that contract are
  named in the module that owns the socket rather than left as a bare message between them. The
  request carries the connection that issued it, because a result belongs to that request and to no
  other link.
  """
  @spec reply(
          pid(),
          String.t(),
          SecretRequest.result_kind(),
          SecretOutcome.t() | SecretOutcome.listing()
        ) :: :ok
  def reply(connection, request_id, kind, outcome) when is_pid(connection) do
    send(connection, {:secret_result, request_id, kind, outcome})
    :ok
  end

  @impl true
  def init(options) do
    :ok = Outbox.open()
    state = build_state(options)

    case Platform.current() do
      {:ok, platform} ->
        token = make_ref()
        Process.send_after(self(), {:reconnect, token}, state.backoff_min_ms)
        {:ok, %{state | reconnect_token: token, platform: platform}}

      {:error, :unsupported_platform} ->
        architecture = :erlang.system_info(:system_architecture) |> List.to_string()

        Logger.warning(
          "node control connection disabled: unsupported host #{architecture}; Biot nodes require Linux"
        )

        {:ok, state}
    end
  end

  @impl true
  def handle_cast(:drain, %State{status: :ready} = state), do: {:noreply, drain(state)}

  # The outbox keeps its reports and its wakeup marker until a ready link drains them, so the
  # drain after the next synchronization sends what waited here.
  def handle_cast(:drain, state), do: {:noreply, state}

  @impl true
  def handle_info({:ssl, socket, data}, %State{socket: socket} = state) do
    state = receive_data(data, state)
    activate(state)
    {:noreply, state}
  end

  def handle_info({:ssl_closed, socket}, %State{socket: socket} = state) do
    {:noreply, disconnect(state, :peer_closed)}
  end

  def handle_info({:ssl_error, socket, reason}, %State{socket: socket} = state) do
    {:noreply, disconnect(state, reason)}
  end

  def handle_info({:ssl, _old_socket, _data}, state), do: {:noreply, state}
  def handle_info({:ssl_closed, _old_socket}, state), do: {:noreply, state}
  def handle_info({:ssl_error, _old_socket, _reason}, state), do: {:noreply, state}

  def handle_info({:reconnect, token}, %State{reconnect_token: token} = state), do: connect(state)

  def handle_info({:reconnect, _token}, state), do: {:noreply, state}

  def handle_info({reference, result}, %State{} = state) when is_reference(reference) do
    case Map.pop(state.pending_reads, reference) do
      {nil, _pending} ->
        {:noreply, state}

      {{task, timer, deadline, reply}, pending} ->
        Process.cancel_timer(timer)
        Process.demonitor(task.ref, [:flush])
        state = %{state | pending_reads: pending}
        finish_read(state, deadline, reply, result)
    end
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %State{} = state
      ) do
    case Map.pop(state.pending_reads, reference) do
      {nil, _pending} ->
        {:noreply, state}

      {{_task, timer, _deadline, _reply}, pending} ->
        Process.cancel_timer(timer)
        {:noreply, %{state | pending_reads: pending}}
    end
  end

  def handle_info({:secret_result, request_id, kind, outcome}, %State{} = state) do
    {:noreply, send_secret_result(state, request_id, kind, outcome)}
  end

  def handle_info({:read_timeout, reference}, %State{} = state) do
    case Map.pop(state.pending_reads, reference) do
      {nil, _pending} ->
        {:noreply, state}

      {{task, _timer, _deadline, _reply}, pending} ->
        Task.Supervisor.terminate_child(Biot.Node.Control.RequestSupervisor, task.pid)
        {:noreply, %{state | pending_reads: pending}}
    end
  end

  def handle_info({:announce, _biot_ids}, %State{status: :ready} = state) do
    intents = Journal.intents()
    Enum.each(intents, &replay_destruction_report/1)
    :ok = Control.report_node_observation(Orphans.detect(Journal.allocations(), intents))

    {:noreply, drain(state)}
  end

  def handle_info({:announce, _biot_ids}, state), do: {:noreply, state}

  def handle_info(
        {:send_heartbeat, socket},
        %State{socket: socket, heartbeat_challenge: challenge} = state
      )
      when not is_nil(challenge) do
    Process.send_after(self(), {:send_heartbeat, socket}, state.heartbeat_interval_ms)
    {:noreply, state}
  end

  def handle_info({:send_heartbeat, socket}, %State{socket: socket, version: version} = state)
      when not is_nil(version) do
    challenge = random_token()

    case send_message(socket, %Message.Heartbeat{challenge: challenge}, version) do
      :ok ->
        Process.send_after(
          self(),
          {:heartbeat_timeout, socket, challenge},
          state.heartbeat_timeout_ms
        )

        Process.send_after(self(), {:send_heartbeat, socket}, state.heartbeat_interval_ms)
        {:noreply, %{state | heartbeat_challenge: challenge}}

      {:error, reason} ->
        {:noreply, disconnect(state, reason)}
    end
  end

  def handle_info({:send_heartbeat, _socket}, state), do: {:noreply, state}

  def handle_info(
        {:heartbeat_timeout, socket, challenge},
        %State{socket: socket, heartbeat_challenge: challenge} = state
      ) do
    {:noreply, disconnect(state, :heartbeat_timeout)}
  end

  def handle_info({:heartbeat_timeout, _socket, _challenge}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{socket: nil}), do: :ok
  def terminate(_reason, %State{socket: socket}), do: :ssl.close(socket)

  defp connect(%State{server_host: nil} = state), do: {:noreply, state}
  defp connect(%State{server_port: nil} = state), do: {:noreply, state}
  defp connect(%State{server_fingerprint: nil} = state), do: {:noreply, state}
  defp connect(%State{registration_id: nil} = state), do: {:noreply, state}
  defp connect(%State{tls: nil} = state), do: {:noreply, state}

  defp connect(state) do
    host = String.to_charlist(state.server_host)

    case :ssl.connect(host, state.server_port, tls_options(state.tls), 10_000) do
      {:ok, socket} -> authenticate_server(socket, state)
      {:error, reason} -> {:noreply, disconnect(state, reason)}
    end
  end

  defp authenticate_server(socket, state) do
    with {:ok, certificate} <- :ssl.peercert(socket),
         {:ok, fingerprint} <- PeerIdentity.from_certificate(certificate),
         true <- fingerprints_match?(fingerprint, state.server_fingerprint),
         :ok <- send_hello(socket, state.registration_id, state.platform),
         :ok <- :ssl.setopts(socket, active: :once) do
      {:noreply,
       %{
         state
         | status: :handshake,
           socket: socket,
           buffer: <<>>,
           reconnect_token: nil,
           heartbeat_challenge: nil
       }}
    else
      false ->
        :ssl.close(socket)
        {:noreply, disconnect(%{state | socket: nil}, :server_fingerprint_mismatch)}

      {:error, reason} ->
        :ssl.close(socket)
        {:noreply, disconnect(%{state | socket: nil}, reason)}
    end
  end

  defp receive_data(data, state) do
    case Frame.decode(state.buffer <> data, state.max_frame_bytes) do
      {:ok, frames, remainder} -> process_frames(frames, %{state | buffer: remainder})
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp process_frames([], state), do: state

  defp process_frames([frame | rest], state) do
    version = if state.status == :handshake, do: :handshake, else: state.version

    case Wire.decode(frame, version) do
      {:ok, message} ->
        case handle_message(message, state) do
          %State{socket: nil} = state -> state
          state -> process_frames(rest, state)
        end

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  defp handle_message(
         %Message.Connected{connection_id: connection_id, selected_protocol_version: version},
         %State{status: :handshake} = state
       ) do
    if version in Version.supported() do
      Process.send_after(self(), {:send_heartbeat, state.socket}, state.heartbeat_interval_ms)

      %{
        state
        | status: :synchronizing,
          connection_id: connection_id,
          version: version,
          staging: nil
      }
    else
      disconnect(state, :unsupported_protocol_version)
    end
  end

  defp handle_message(%Message.Reject{reason: reason}, %State{status: :handshake} = state) do
    disconnect(state, {:rejected, reason})
  end

  defp handle_message(
         %Message.SynchronizeBegin{connection_id: connection_id, count: count},
         %State{status: :synchronizing, connection_id: connection_id, staging: nil} = state
       ) do
    case Staging.begin(connection_id, count, state.max_staged_specs) do
      {:ok, staging} -> %{state | staging: staging}
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp handle_message(
         %Message.SynchronizeItem{biot_spec: spec},
         %State{status: :synchronizing, staging: %Staging{} = staging} = state
       ) do
    case Staging.add(staging, spec) do
      {:ok, staging} -> %{state | staging: staging}
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp handle_message(
         %Message.SynchronizeEnd{connection_id: connection_id},
         %State{status: :synchronizing, staging: %Staging{} = staging} = state
       ) do
    case Staging.complete(staging, connection_id) do
      {:ok, specs} -> commit_synchronization(specs, state)
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp handle_message(
         %Message.Desired{},
         %State{staging: %Staging{}} = state
       ) do
    disconnect(state, :desired_during_snapshot)
  end

  defp handle_message(%Message.Desired{biot_spec: spec}, %State{status: :ready} = state) do
    case Journal.put_intent(spec) do
      {:ok, intent} ->
        replay_destruction_report(intent)
        acknowledge_desired(spec, state)

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  defp handle_message(%Message.Diagnostic{} = request, %State{status: :ready} = state) do
    start_read(
      state,
      request.timeout_ms,
      fn -> query_diagnostic(request) end,
      &%Message.DiagnosticResult{request_id: request.request_id, result: &1}
    )
  end

  defp handle_message(%Message.RuntimeLogs{} = request, %State{status: :ready} = state) do
    start_read(
      state,
      request.timeout_ms,
      fn -> query_runtime_logs(request) end,
      &%Message.RuntimeLogsResult{request_id: request.request_id, result: &1}
    )
  end

  defp handle_message(%Message.DeliverSecret{} = request, %State{status: :ready} = state) do
    queue(state, request, {:deliver_secret, request.name, request.value})
  end

  defp handle_message(%Message.RemoveSecret{} = request, %State{status: :ready} = state) do
    queue(state, request, {:remove_secret, request.name})
  end

  defp handle_message(%Message.ListSecrets{} = request, %State{status: :ready} = state) do
    queue(state, request, :list_secrets)
  end

  defp handle_message(
         %Message.DeliverFetchCredential{} = request,
         %State{status: :ready} = state
       ) do
    queue(state, request, {:deliver_fetch_credential, request.source, request.value})
  end

  defp handle_message(
         %Message.RemoveFetchCredential{} = request,
         %State{status: :ready} = state
       ) do
    queue(state, request, {:remove_fetch_credential, request.source})
  end

  defp handle_message(
         %Message.Heartbeat{challenge: challenge},
         %State{status: status} = state
       )
       when status in [:synchronizing, :ready] do
    case send_message(
           state.socket,
           %Message.HeartbeatResponse{challenge: challenge},
           state.version
         ) do
      :ok -> state
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp handle_message(
         %Message.HeartbeatResponse{challenge: response},
         %State{status: status} = state
       )
       when status in [:synchronizing, :ready] do
    if Liveness.response_matches?(state.heartbeat_challenge, response),
      do: %{state | heartbeat_challenge: nil},
      else: state
  end

  defp handle_message(_message, state), do: disconnect(state, :unexpected_message)

  defp commit_synchronization(specs, state) do
    case Journal.replace_intents(specs) do
      {:ok, removed_biot_ids} ->
        # Snapshot omission is the one authority that forgets private output for an unassigned Biot.
        Enum.each(removed_biot_ids, fn biot_id ->
          Diagnostics.forget(biot_id)
          RuntimeLogs.forget(biot_id)
        end)

        acknowledge_synchronization(specs, state)

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  defp acknowledge_synchronization(specs, state) do
    case send_access_applied(specs, state) do
      :ok -> finish_synchronization(specs, state)
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp finish_synchronization(specs, state) do
    biot_ids = Enum.map(specs, & &1.execution.biot_id)
    warn_missing_controller(Controllers.synchronized(biot_ids))

    case send_message(
           state.socket,
           %Message.Synchronized{connection_id: state.connection_id},
           state.version
         ) do
      :ok ->
        send(self(), {:announce, biot_ids})
        %{state | status: :ready, staging: nil, backoff_ms: state.backoff_min_ms}

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  defp acknowledge_desired(spec, state) do
    case send_access_applied([spec], state) do
      :ok ->
        warn_missing_controller(Controllers.intent_changed(spec.execution.biot_id))
        state

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  defp activate(%State{socket: nil}), do: :ok
  defp activate(%State{socket: socket}), do: :ssl.setopts(socket, active: :once)

  # A failed send loses the reports this drain took. That costs nothing: the reconnect
  # synchronizes, which pokes every controller into reporting what it inspects then.
  defp drain(%State{} = state) do
    messages = Enum.map(Outbox.drain(), &report_message/1)

    case send_all(state.socket, messages, state.version) do
      :ok -> state
      {:error, reason} -> disconnect(state, reason)
    end
  end

  # Durable intent without a live controller is a node fault, not a link fault. The controller's
  # owner keeps trying to start it, and the link stays up for the biots that do have one.
  defp warn_missing_controller(:ok), do: :ok

  defp warn_missing_controller({:error, {biot_id, reason}}) do
    Logger.error(
      "no controller for biot #{BiotId.to_string(biot_id)}: #{inspect(reason)}; the node keeps trying"
    )
  end

  defp disconnect(%State{socket: socket} = state, reason) when not is_nil(socket) do
    :ssl.close(socket)
    disconnect(%{state | socket: nil}, reason)
  end

  defp disconnect(state, reason) do
    Logger.info("node control connection disconnected: #{inspect(reason)}")
    token = make_ref()
    Process.send_after(self(), {:reconnect, token}, state.backoff_ms)
    cancel_reads(state.pending_reads)

    %{
      state
      | status: :disconnected,
        socket: nil,
        buffer: <<>>,
        version: nil,
        connection_id: nil,
        staging: nil,
        heartbeat_challenge: nil,
        pending_reads: %{},
        reconnect_token: token,
        backoff_ms: min(state.backoff_ms * 2, state.backoff_max_ms)
    }
  end

  # The server keeps sending intent for a destroyed biot until it acknowledges the report, so the
  # node repeats the receipt on every link that becomes ready and on every repeat of the intent.
  defp replay_destruction_report(%LocalIntent{destruction_report: nil}), do: :ok

  defp replay_destruction_report(%LocalIntent{} = intent) do
    Control.report_observation(intent.biot_id, intent.destruction_report)
  end

  defp build_state(options) do
    backoff_min = option(options, :reconnect_backoff_min_ms, 250)

    %State{
      server_host: option(options, :server_host, nil),
      server_port: option(options, :server_port, nil),
      server_fingerprint: option(options, :server_fingerprint, nil),
      registration_id: registration_id(option(options, :registration_id, nil)),
      tls: option(options, :tls, nil),
      max_frame_bytes: Application.fetch_env!(:biot_node, :max_frame_bytes),
      max_staged_specs: Application.fetch_env!(:biot_node, :max_staged_specs),
      heartbeat_interval_ms: option(options, :heartbeat_interval_ms, 30_000),
      heartbeat_timeout_ms: option(options, :heartbeat_timeout_ms, 10_000),
      backoff_min_ms: backoff_min,
      backoff_max_ms: option(options, :reconnect_backoff_max_ms, 30_000),
      backoff_ms: backoff_min
    }
  end

  defp option(options, key, default) do
    Keyword.get(options, key, Application.get_env(:biot_node, key, default))
  end

  defp registration_id(nil), do: nil
  defp registration_id(%RegistrationId{} = registration_id), do: registration_id

  defp registration_id(value) do
    {:ok, registration_id} = RegistrationId.parse(value)
    registration_id
  end

  defp start_read(state, timeout_ms, query, reply) do
    task = Task.Supervisor.async_nolink(Biot.Node.Control.RequestSupervisor, query)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    timer = Process.send_after(self(), {:read_timeout, task.ref}, timeout_ms)
    pending = Map.put(state.pending_reads, task.ref, {task, timer, deadline, reply})
    %{state | pending_reads: pending}
  end

  defp finish_read(state, deadline, reply, result) do
    if System.monotonic_time(:millisecond) <= deadline do
      send_read_result(state, reply.(result))
    else
      {:noreply, state}
    end
  end

  defp send_read_result(state, message) do
    case send_message(state.socket, message, state.version) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:noreply, disconnect(state, reason)}
    end
  end

  # The controller owns the queue and its deadline, so this hands the request over and answers only
  # when it cannot: a biot with no controller has no allocation here. The deadline starts now,
  # which is later than the deadline the server is already counting for its caller.
  defp queue(state, request, operation) do
    secret_request =
      SecretRequest.new(request.request_id, operation, request.timeout_ms, self())

    case Controllers.secret_request(request.biot_id, secret_request) do
      :ok ->
        state

      outcome ->
        send_secret_result(
          state,
          request.request_id,
          SecretRequest.result_kind(operation),
          outcome
        )
    end
  end

  defp send_secret_result(%State{status: :ready} = state, request_id, kind, outcome) do
    case send_message(
           state.socket,
           secret_result_message(kind, request_id, outcome),
           state.version
         ) do
      :ok -> state
      {:error, reason} -> disconnect(state, reason)
    end
  end

  # A result for a link that is no longer ready is dropped: the server released its caller when the
  # connection closed, and it ignores a late reply on the next one.
  defp send_secret_result(%State{} = state, _request_id, _kind, _outcome), do: state

  defp secret_result_message(:secret, request_id, outcome) do
    %Message.SecretResult{request_id: request_id, result: outcome}
  end

  defp secret_result_message(:secret_list, request_id, outcome) do
    %Message.SecretListResult{request_id: request_id, result: outcome}
  end

  defp secret_result_message(:fetch_credential, request_id, outcome) do
    %Message.FetchCredentialResult{request_id: request_id, result: outcome}
  end

  defp query_diagnostic(request) do
    case Diagnostics.fetch(request.diagnostic_id, request.max_bytes) do
      {:ok, value} -> value
      :not_found -> :not_found
    end
  end

  defp query_runtime_logs(request) do
    case RuntimeLogs.fetch(request.biot_id, request.max_bytes) do
      {:ok, value} -> value
      :not_found -> :not_found
    end
  end

  defp cancel_reads(pending_reads) do
    Enum.each(pending_reads, fn {_reference, {task, timer, _deadline, _reply}} ->
      Process.cancel_timer(timer)
      Task.Supervisor.terminate_child(Biot.Node.Control.RequestSupervisor, task.pid)
    end)
  end

  defp tls_options(tls) do
    Keyword.merge(tls,
      verify: :verify_peer,
      active: false,
      mode: :binary,
      packet: :raw,
      server_name_indication: :disable
    )
  end

  defp send_hello(socket, registration_id, platform) do
    send_message(
      socket,
      %Message.Hello{
        registration_id: registration_id,
        supported_protocol_versions: Version.supported(),
        platform: platform
      },
      :handshake
    )
  end

  defp report_message({:observation, biot_id, report}) do
    %Message.Observation{biot_id: biot_id, execution_report: report}
  end

  defp report_message({:resolution, environment_id, manifest}) do
    %Message.Resolution{environment_id: environment_id, manifest: manifest}
  end

  defp report_message({:node_observation, orphaned_allocations}) do
    %Message.NodeObservation{orphaned_allocations: orphaned_allocations}
  end

  defp send_message(socket, message, version) do
    with {:ok, encoded} <- Wire.encode(message, version) do
      :ssl.send(socket, Frame.encode(encoded))
    end
  end

  defp send_access_applied(specs, state) do
    # The durable journal write is the honest acknowledgement until step 20 owns stream revisions.
    messages =
      Enum.map(specs, fn spec ->
        %Message.AccessApplied{
          biot_id: spec.execution.biot_id,
          access_revision: spec.access_revision
        }
      end)

    send_all(state.socket, messages, state.version)
  end

  defp send_all(socket, messages, version) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case send_message(socket, message, version) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp random_token, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp fingerprints_match?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp fingerprints_match?(_left, _right), do: false
end
