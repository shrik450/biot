defmodule Biot.Server.Control.Connection do
  @moduledoc "Owns one authenticated server-side node control connection and its pending requests."

  use ThousandIsland.Handler

  require Logger

  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Liveness
  alias Biot.Protocol.Message
  alias Biot.Protocol.PeerIdentity
  alias Biot.Protocol.Version
  alias Biot.Protocol.Wire
  alias Biot.Server.Biots
  alias Biot.Server.Control.Synchronization
  alias Biot.Server.NodeConnections
  alias Biot.Server.Nodes.Status
  alias Biot.Server.NodeWake
  alias Biot.Server.Repo
  alias Biot.Server.Reports
  alias Biot.Server.Schema.Node
  alias ThousandIsland.Socket

  defmodule State do
    @moduledoc false
    defstruct [
      :max_frame_bytes,
      :handshake_timeout_ms,
      :heartbeat_interval_ms,
      :heartbeat_timeout_ms,
      :desired_sweep_interval_ms,
      phase: :handshake,
      peer_identity: nil,
      buffer: <<>>,
      handshake_timer: nil,
      heartbeat_challenge: nil,
      version: nil,
      node_id: nil,
      connection_id: nil,
      pending_requests: %{}
    ]
  end

  @spec request_diagnostic(
          pid(),
          Biot.Protocol.PrivateDiagnosticId.t(),
          pos_integer(),
          pos_integer()
        ) ::
          {:ok, {binary(), boolean()}} | {:error, :not_found | :temporarily_unavailable}
  def request_diagnostic(pid, diagnostic_id, max_bytes, timeout_ms) do
    GenServer.call(pid, {:diagnostic, diagnostic_id, max_bytes, timeout_ms}, timeout_ms + 1_000)
  catch
    :exit, _reason -> {:error, :temporarily_unavailable}
  end

  @spec request_runtime_logs(
          pid(),
          Biot.Protocol.BiotId.t(),
          pos_integer(),
          pos_integer()
        ) ::
          {:ok, {Biot.Protocol.IncarnationId.t(), binary(), boolean()}}
          | {:error, :not_found | :temporarily_unavailable}
  def request_runtime_logs(pid, biot_id, max_bytes, timeout_ms) do
    GenServer.call(pid, {:runtime_logs, biot_id, max_bytes, timeout_ms}, timeout_ms + 1_000)
  catch
    :exit, _reason -> {:error, :temporarily_unavailable}
  end

  @secret_calls [
    :deliver_secret,
    :remove_secret,
    :list_secrets,
    :deliver_fetch_credential,
    :remove_fetch_credential
  ]

  @typedoc "What a secret or fetch credential request answers its caller."
  @type secret_reply :: :ok | {:error, :temporarily_unavailable}

  @spec deliver_secret(
          pid(),
          Biot.Protocol.BiotId.t(),
          Biot.Protocol.SecretName.t(),
          Biot.Protocol.SecretValue.t(),
          pos_integer()
        ) :: secret_reply()
  def deliver_secret(pid, biot_id, name, value, timeout_ms) do
    request(pid, {:deliver_secret, biot_id, name, value, timeout_ms}, timeout_ms)
  end

  @spec remove_secret(
          pid(),
          Biot.Protocol.BiotId.t(),
          Biot.Protocol.SecretName.t(),
          pos_integer()
        ) :: secret_reply()
  def remove_secret(pid, biot_id, name, timeout_ms) do
    request(pid, {:remove_secret, biot_id, name, timeout_ms}, timeout_ms)
  end

  @spec list_secrets(pid(), Biot.Protocol.BiotId.t(), pos_integer()) ::
          {:ok, [Biot.Protocol.SecretName.t()]} | {:error, :temporarily_unavailable}
  def list_secrets(pid, biot_id, timeout_ms) do
    request(pid, {:list_secrets, biot_id, timeout_ms}, timeout_ms)
  end

  @spec deliver_fetch_credential(
          pid(),
          Biot.Protocol.BiotId.t(),
          Biot.Protocol.RepositorySource.t(),
          Biot.Protocol.AuthorizationValue.t(),
          pos_integer()
        ) :: secret_reply()
  def deliver_fetch_credential(pid, biot_id, source, value, timeout_ms) do
    request(pid, {:deliver_fetch_credential, biot_id, source, value, timeout_ms}, timeout_ms)
  end

  @spec remove_fetch_credential(
          pid(),
          Biot.Protocol.BiotId.t(),
          Biot.Protocol.RepositorySource.t(),
          pos_integer()
        ) :: secret_reply()
  def remove_fetch_credential(pid, biot_id, source, timeout_ms) do
    request(pid, {:remove_fetch_credential, biot_id, source, timeout_ms}, timeout_ms)
  end

  # The caller waits one second past the request's own deadline, so the connection's timer is what
  # answers rather than this call giving up first and leaving the request pending.
  defp request(pid, call, timeout_ms) do
    GenServer.call(pid, call, timeout_ms + 1_000)
  catch
    :exit, _reason -> {:error, :temporarily_unavailable}
  end

  @impl ThousandIsland.Handler
  def handle_connection(socket, options) do
    with {:ok, certificate} <- Socket.peercert(socket),
         {:ok, peer_identity} <- PeerIdentity.from_certificate(certificate) do
      state = initial_state(options, peer_identity)
      timer = Process.send_after(self(), :handshake_deadline, state.handshake_timeout_ms)
      {:continue, %{state | handshake_timer: timer}}
    else
      {:error, reason} -> close(reason, %State{})
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %State{} = state) do
    buffer = state.buffer <> data

    case Frame.decode(buffer, state.max_frame_bytes) do
      {:ok, frames, remainder} -> process_frames(frames, socket, %{state | buffer: remainder})
      {:error, reason} -> close(reason, state)
    end
  end

  @impl GenServer
  def handle_info({:biot_spec_changed, biot_id}, {socket, %State{phase: :ready} = state}) do
    case send_desired(socket, biot_id, state.version) do
      :ok -> {:noreply, {socket, state}}
      {:error, reason} -> {:stop, {:shutdown, reason}, {socket, state}}
    end
  end

  def handle_info(
        {:biot_spec_changed, _biot_id},
        {socket, %State{phase: :synchronizing} = state}
      ) do
    # The snapshot sends the set; the sweep covers later intent, including dropped wakes.
    {:noreply, {socket, state}}
  end

  def handle_info(:desired_sweep, {socket, %State{phase: :ready} = state}) do
    case send_behind_specs(socket, state) do
      :ok ->
        Process.send_after(self(), :desired_sweep, state.desired_sweep_interval_ms)
        {:noreply, {socket, state}}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, {socket, state}}
    end
  end

  def handle_info(:handshake_deadline, {socket, %State{phase: :handshake} = state}) do
    Logger.info("closing node control connection: handshake deadline expired")
    {:stop, {:shutdown, :handshake_deadline}, {socket, state}}
  end

  def handle_info(:handshake_deadline, {socket, %State{} = state}) do
    {:noreply, {socket, state}}
  end

  def handle_info(:send_heartbeat, {socket, %State{version: nil} = state}) do
    {:noreply, {socket, state}}
  end

  def handle_info(:send_heartbeat, {socket, %State{heartbeat_challenge: challenge} = state})
      when not is_nil(challenge) do
    Process.send_after(self(), :send_heartbeat, state.heartbeat_interval_ms)
    {:noreply, {socket, state}}
  end

  def handle_info(:send_heartbeat, {socket, %State{} = state}) do
    challenge = random_token()
    message = %Message.Heartbeat{challenge: challenge}

    case send_message(socket, message, state.version) do
      :ok ->
        Process.send_after(self(), {:heartbeat_timeout, challenge}, state.heartbeat_timeout_ms)
        Process.send_after(self(), :send_heartbeat, state.heartbeat_interval_ms)
        {:noreply, {socket, %{state | heartbeat_challenge: challenge}}}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, {socket, state}}
    end
  end

  def handle_info(
        {:heartbeat_timeout, challenge},
        {socket, %State{heartbeat_challenge: challenge} = state}
      ) do
    {:stop, {:shutdown, :heartbeat_timeout}, {socket, state}}
  end

  def handle_info({:heartbeat_timeout, _challenge}, {socket, %State{} = state}) do
    {:noreply, {socket, state}}
  end

  def handle_info({:request_timeout, request_id}, {socket, %State{} = state}) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        {:noreply, {socket, state}}

      {{from, _timer, _reply}, pending} ->
        GenServer.reply(from, {:error, :temporarily_unavailable})
        {:noreply, {socket, %{state | pending_requests: pending}}}
    end
  end

  def handle_info(reason, {socket, %State{} = state})
      when reason in [:replaced, :registration_changed] do
    {:stop, {:shutdown, reason}, {socket, state}}
  end

  @impl GenServer
  def handle_call(
        {:diagnostic, diagnostic_id, max_bytes, timeout_ms},
        from,
        {socket, %State{phase: :ready} = state}
      ) do
    message = fn request_id ->
      %Message.Diagnostic{
        request_id: request_id,
        diagnostic_id: diagnostic_id,
        max_bytes: max_bytes,
        timeout_ms: timeout_ms
      }
    end

    start_request(socket, state, from, timeout_ms, message, &diagnostic_reply/1)
  end

  def handle_call({:diagnostic, _id, _max, _timeout}, _from, {socket, %State{} = state}) do
    {:reply, {:error, :temporarily_unavailable}, {socket, state}}
  end

  def handle_call(
        {:runtime_logs, biot_id, max_bytes, timeout_ms},
        from,
        {socket, %State{phase: :ready} = state}
      ) do
    message = fn request_id ->
      %Message.RuntimeLogs{
        request_id: request_id,
        biot_id: biot_id,
        max_bytes: max_bytes,
        timeout_ms: timeout_ms
      }
    end

    start_request(socket, state, from, timeout_ms, message, &runtime_logs_reply/1)
  end

  def handle_call({:runtime_logs, _id, _max, _timeout}, _from, {socket, %State{} = state}) do
    {:reply, {:error, :temporarily_unavailable}, {socket, state}}
  end

  def handle_call(
        {:deliver_secret, biot_id, name, value, timeout_ms},
        from,
        {socket, %State{phase: :ready} = state}
      ) do
    message = fn request_id ->
      %Message.DeliverSecret{
        request_id: request_id,
        biot_id: biot_id,
        name: name,
        value: value,
        timeout_ms: timeout_ms
      }
    end

    start_request(socket, state, from, timeout_ms, message, &secret_reply/1)
  end

  def handle_call(
        {:remove_secret, biot_id, name, timeout_ms},
        from,
        {socket, %State{phase: :ready} = state}
      ) do
    message = fn request_id ->
      %Message.RemoveSecret{
        request_id: request_id,
        biot_id: biot_id,
        name: name,
        timeout_ms: timeout_ms
      }
    end

    start_request(socket, state, from, timeout_ms, message, &secret_reply/1)
  end

  def handle_call(
        {:list_secrets, biot_id, timeout_ms},
        from,
        {socket, %State{phase: :ready} = state}
      ) do
    message = fn request_id ->
      %Message.ListSecrets{request_id: request_id, biot_id: biot_id, timeout_ms: timeout_ms}
    end

    start_request(socket, state, from, timeout_ms, message, &secret_list_reply/1)
  end

  def handle_call(
        {:deliver_fetch_credential, biot_id, source, value, timeout_ms},
        from,
        {socket, %State{phase: :ready} = state}
      ) do
    message = fn request_id ->
      %Message.DeliverFetchCredential{
        request_id: request_id,
        biot_id: biot_id,
        source: source,
        value: value,
        timeout_ms: timeout_ms
      }
    end

    start_request(socket, state, from, timeout_ms, message, &secret_reply/1)
  end

  def handle_call(
        {:remove_fetch_credential, biot_id, source, timeout_ms},
        from,
        {socket, %State{phase: :ready} = state}
      ) do
    message = fn request_id ->
      %Message.RemoveFetchCredential{
        request_id: request_id,
        biot_id: biot_id,
        source: source,
        timeout_ms: timeout_ms
      }
    end

    start_request(socket, state, from, timeout_ms, message, &secret_reply/1)
  end

  # A link that is not ready cannot carry a request, and the caller's answer is the same one a
  # timeout gives: the node could not be reached, so nothing is known about the biot's secrets.
  def handle_call(request, _from, {socket, %State{} = state})
      when elem(request, 0) in @secret_calls do
    {:reply, {:error, :temporarily_unavailable}, {socket, state}}
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state), do: cleanup(state)

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    Logger.warning("node control connection closed: #{inspect(reason)}")
    cleanup(state)
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state), do: cleanup(state)

  defp initial_state(options, peer_identity) do
    # Timing options let integration checks exercise deadlines without production waits.
    %State{
      peer_identity: peer_identity,
      max_frame_bytes: Application.fetch_env!(:biot_server, :max_frame_bytes),
      handshake_timeout_ms: option(options, :handshake_timeout_ms),
      heartbeat_interval_ms: option(options, :heartbeat_interval_ms),
      heartbeat_timeout_ms: option(options, :heartbeat_timeout_ms),
      desired_sweep_interval_ms: option(options, :desired_sweep_interval_ms)
    }
  end

  defp option(options, key) do
    Keyword.get(options, key, Application.fetch_env!(:biot_server, key))
  end

  defp process_frames([], _socket, state), do: {:continue, state}

  defp process_frames([frame | rest], socket, state) do
    version = if state.phase == :handshake, do: :handshake, else: state.version

    with {:ok, message} <- Wire.decode(frame, version),
         {:continue, state} <- handle_message(message, socket, state) do
      process_frames(rest, socket, state)
    else
      {:close, state} -> {:close, state}
      {:error, reason} -> close(reason, state)
    end
  end

  defp handle_message(%Message.Hello{} = hello, socket, %State{phase: :handshake} = state) do
    state = cancel_handshake_deadline(state)

    with {:ok, node} <- authenticate(hello.registration_id, state.peer_identity),
         {:ok, version} <-
           Version.select_version(hello.supported_protocol_versions, Version.supported()),
         {:ok, connection_id} <- new_connection_id(),
         :ok <- claim_node(node.id, connection_id),
         {:ok, node} <- store_platform(node, hello.platform),
         :ok <- send_connected(socket, connection_id, version),
         :ok <- NodeWake.subscribe(node.id),
         :ok <- send_snapshot(socket, node.id, connection_id, version) do
      NodeConnections.put(node.id, %{connection_id: connection_id, state: :synchronizing})
      Process.send_after(self(), :send_heartbeat, state.heartbeat_interval_ms)

      {:continue,
       %{
         state
         | phase: :synchronizing,
           version: version,
           node_id: node.id,
           connection_id: connection_id
       }}
    else
      {:error, reason} ->
        case rejection_reason(reason) do
          nil -> :ok
          rejection -> send_message(socket, %Message.Reject{reason: rejection}, :handshake)
        end

        close(reason, state)
    end
  end

  defp handle_message(
         %Message.Synchronized{connection_id: connection_id},
         _socket,
         %State{phase: :synchronizing, connection_id: connection_id} = state
       ) do
    case NodeConnections.put(state.node_id, %{connection_id: connection_id, state: :ready}) do
      :ok ->
        # The snapshot sends the set; the sweep covers later intent, including dropped wakes.
        Process.send_after(self(), :desired_sweep, state.desired_sweep_interval_ms)
        {:continue, %{state | phase: :ready}}

      {:error, reason} ->
        close(reason, state)
    end
  end

  defp handle_message(%Message.Observation{} = message, _socket, %State{phase: :ready} = state) do
    result =
      Reports.observation(
        state.node_id,
        state.connection_id,
        message.biot_id,
        message.execution_report
      )

    log_report_result(result, state.node_id, "observation")
    {:continue, state}
  end

  defp handle_message(
         %Message.AccessApplied{} = message,
         _socket,
         %State{phase: phase} = state
       )
       when phase in [:synchronizing, :ready] do
    # The node acknowledges durable snapshot access before it sends synchronized.
    result =
      Reports.access_applied(
        state.node_id,
        state.connection_id,
        message.biot_id,
        message.access_revision
      )

    log_report_result(result, state.node_id, "access_applied")
    {:continue, state}
  end

  defp handle_message(%Message.Resolution{} = message, _socket, %State{phase: :ready} = state) do
    result = Reports.resolution(state.node_id, message.environment_id, message.manifest)
    log_report_result(result, state.node_id, "resolution")
    {:continue, state}
  end

  defp handle_message(
         %Message.NodeObservation{orphaned_allocations: allocations},
         _socket,
         %State{phase: :ready} = state
       ) do
    result = Reports.node_observation(state.node_id, state.connection_id, allocations)
    log_report_result(result, state.node_id, "node_observation")
    {:continue, state}
  end

  defp handle_message(%Message.Heartbeat{challenge: challenge}, socket, %State{} = state) do
    case send_message(socket, %Message.HeartbeatResponse{challenge: challenge}, state.version) do
      :ok -> {:continue, state}
      {:error, reason} -> close(reason, state)
    end
  end

  defp handle_message(
         %Message.HeartbeatResponse{challenge: response},
         _socket,
         %State{} = state
       ) do
    if Liveness.response_matches?(state.heartbeat_challenge, response) do
      {:continue, %{state | heartbeat_challenge: nil}}
    else
      {:continue, state}
    end
  end

  defp handle_message(
         %Message.DiagnosticResult{request_id: request_id, result: result},
         _socket,
         %State{phase: :ready} = state
       ) do
    complete_request(state, request_id, result)
  end

  defp handle_message(
         %Message.RuntimeLogsResult{request_id: request_id, result: result},
         _socket,
         %State{phase: :ready} = state
       ) do
    complete_request(state, request_id, result)
  end

  defp handle_message(%Message.SecretResult{} = message, _socket, %State{phase: :ready} = state) do
    complete_request(state, message.request_id, message.result)
  end

  defp handle_message(
         %Message.SecretListResult{} = message,
         _socket,
         %State{phase: :ready} = state
       ) do
    complete_request(state, message.request_id, message.result)
  end

  defp handle_message(
         %Message.FetchCredentialResult{} = message,
         _socket,
         %State{phase: :ready} = state
       ) do
    complete_request(state, message.request_id, message.result)
  end

  defp handle_message(_message, _socket, state), do: close(:unexpected_message, state)

  defp authenticate(registration_id, peer_identity) do
    case Repo.get_by(Node, registration: registration_id) do
      nil ->
        {:error, :unknown_registration}

      %Node{peer_identity: identity} = node ->
        if fingerprints_match?(identity, peer_identity) do
          authenticate_status(node)
        else
          {:error, :peer_identity_mismatch}
        end
    end
  end

  defp authenticate_status(%Node{} = node) do
    with :ok <- Status.accepts_connection(node.status), do: {:ok, node}
  end

  defp claim_node(node_id, connection_id) do
    # The Registry uses NodeId keys so the newest authenticated connection replaces the old one.
    case Registry.register(Biot.Server.Control.Registry, node_id, connection_id) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, pid}} ->
        monitor = Process.monitor(pid)
        send(pid, :replaced)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> claim_node(node_id, connection_id)
        after
          5_000 ->
            Process.demonitor(monitor, [:flush])
            {:error, :existing_connection_did_not_close}
        end
    end
  end

  defp store_platform(%Node{} = node, platform) do
    # Replace the platform on every authenticated connection because the live node is authoritative.
    node
    |> Ecto.Changeset.change(platform: platform)
    |> Repo.update()
  end

  defp send_connected(socket, connection_id, version) do
    send_message(
      socket,
      %Message.Connected{
        connection_id: connection_id,
        selected_protocol_version: version
      },
      :handshake
    )
  end

  defp send_snapshot(socket, node_id, connection_id, version) do
    specs = Synchronization.specs(node_id)

    messages =
      [%Message.SynchronizeBegin{connection_id: connection_id, count: length(specs)}] ++
        Enum.map(specs, &%Message.SynchronizeItem{biot_spec: &1}) ++
        [%Message.SynchronizeEnd{connection_id: connection_id}]

    send_all(socket, messages, version)
  end

  defp send_message(socket, message, version) do
    with {:ok, encoded} <- Wire.encode(message, version) do
      Socket.send(socket, Frame.encode(encoded))
    end
  end

  defp cleanup(%State{node_id: nil}), do: :ok

  defp cleanup(%State{} = state) do
    NodeConnections.delete(state.node_id, state.connection_id)

    Enum.each(state.pending_requests, fn {_request_id, {from, timer, _reply}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :temporarily_unavailable})
    end)

    :ok
  end

  defp diagnostic_reply(:not_found), do: {:error, :not_found}
  defp diagnostic_reply({content, truncated}), do: {:ok, {content, truncated}}

  defp runtime_logs_reply(:not_found), do: {:error, :not_found}

  defp runtime_logs_reply({incarnation_id, content, truncated}) do
    {:ok, {incarnation_id, content, truncated}}
  end

  # An allocation the node does not have yet and a write it could not make are both states that
  # pass, and neither tells the owner anything they can act on beyond trying again.
  defp secret_reply(:ok), do: :ok
  defp secret_reply(:no_allocation), do: {:error, :temporarily_unavailable}
  defp secret_reply({:failure, _code}), do: {:error, :temporarily_unavailable}

  defp secret_list_reply({:ok, names}), do: {:ok, names}
  defp secret_list_reply(outcome), do: secret_reply(outcome)

  # The deadline starts before the send, because the node's own deadline starts when it receives the
  # frame and a timer started afterwards could be the later of the two. A send that fails cancels
  # the timer again, so an unsent request never holds one.
  defp start_request(socket, state, from, timeout_ms, message, reply) do
    request_id = random_token()
    timer = Process.send_after(self(), {:request_timeout, request_id}, timeout_ms)

    case send_message(socket, message.(request_id), state.version) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, {from, timer, reply})
        {:noreply, {socket, %{state | pending_requests: pending}}}

      {:error, _reason} ->
        Process.cancel_timer(timer)
        {:reply, {:error, :temporarily_unavailable}, {socket, state}}
    end
  end

  defp complete_request(state, request_id, result) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        {:continue, state}

      {{from, timer, reply}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, reply.(result))
        {:continue, %{state | pending_requests: pending}}
    end
  end

  defp new_connection_id, do: ConnectionId.parse(Ecto.UUID.generate())

  defp random_token, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp cancel_handshake_deadline(%State{handshake_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | handshake_timer: nil}
  end

  defp send_behind_specs(socket, state) do
    with {:ok, messages} <- desired_messages(state.node_id, state.connection_id) do
      send_all(socket, messages, state.version)
    end
  end

  defp send_desired(socket, biot_id, version) do
    with {:ok, spec} <- Biots.spec(biot_id) do
      send_message(socket, %Message.Desired{biot_spec: spec}, version)
    end
  end

  defp desired_messages(node_id, connection_id) do
    node_id
    |> Synchronization.behind(connection_id)
    |> Enum.reduce_while({:ok, []}, fn biot_id, {:ok, messages} ->
      case Biots.spec(biot_id) do
        {:ok, spec} -> {:cont, {:ok, [%Message.Desired{biot_spec: spec} | messages]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_all(socket, messages, version) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case send_message(socket, message, version) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rejection_reason(reason)
       when reason in [:unknown_registration, :peer_identity_mismatch],
       do: :registration_rejected

  defp rejection_reason(reason)
       when reason in [
              :unsupported_protocol_version,
              :registration_retired,
              :registration_abandoned
            ],
       do: reason

  defp rejection_reason(_reason), do: nil

  defp fingerprints_match?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp fingerprints_match?(_left, _right), do: false

  defp log_report_result({:ok, {:ignored, reason}}, node_id, message_kind) do
    Logger.debug(
      "node report ignored: node_id=#{inspect(node_id)} message_kind=#{message_kind} reason=#{inspect(reason)}"
    )
  end

  defp log_report_result({:error, reason}, node_id, message_kind) do
    Logger.warning(
      "node report failed: node_id=#{inspect(node_id)} message_kind=#{message_kind} reason=#{inspect(reason)}"
    )
  end

  defp log_report_result({:ok, _result}, _node_id, _message_kind), do: :ok

  defp close(reason, state) do
    Logger.info("closing node control connection: #{inspect(reason)}")
    {:close, state}
  end
end
