defmodule Biot.Node.Control.Connection do
  @moduledoc "Owns the node TLS control connection, synchronization, heartbeats, and reconnects."

  use GenServer

  require Logger

  alias Biot.Node.Diagnostics
  alias Biot.Node.Intents
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Liveness
  alias Biot.Protocol.Message
  alias Biot.Protocol.PeerIdentity
  alias Biot.Protocol.Platform
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.Version
  alias Biot.Protocol.Wire

  defmodule State do
    @moduledoc false
    defstruct status: :disconnected,
              socket: nil,
              buffer: <<>>,
              version: nil,
              connection_id: nil,
              heartbeat_challenge: nil,
              reconnect_token: nil,
              backoff_ms: 250,
              server_host: nil,
              server_port: nil,
              server_fingerprint: nil,
              registration_id: nil,
              platform: nil,
              tls: nil,
              max_frame_bytes: 1_000_000,
              heartbeat_interval_ms: 30_000,
              heartbeat_timeout_ms: 10_000,
              backoff_min_ms: 250,
              backoff_max_ms: 30_000
  end

  @type report ::
          {:observation, Biot.Protocol.BiotId.t(), Biot.Protocol.ExecutionReport.t()}
          | {:resolution, Biot.Protocol.EnvironmentId.t(), Biot.Protocol.Manifest.t()}
          | {:node_observation, [Biot.Protocol.OrphanedAllocation.t()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @spec send_report(report()) :: :ok | {:error, :disconnected}
  def send_report(report), do: GenServer.call(__MODULE__, {:report, report})

  @impl true
  def init(options) do
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
  def handle_call({:report, report}, _from, %State{status: :ready} = state) do
    case send_message(state.socket, report_message(report), state.version) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, :disconnected}, disconnect(state, reason)}
    end
  end

  def handle_call({:report, _report}, _from, state) do
    {:reply, {:error, :disconnected}, state}
  end

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
      %{state | status: :synchronizing, connection_id: connection_id, version: version}
    else
      disconnect(state, :unsupported_protocol_version)
    end
  end

  defp handle_message(%Message.Reject{reason: reason}, %State{status: :handshake} = state) do
    disconnect(state, {:rejected, reason})
  end

  defp handle_message(
         %Message.Synchronize{connection_id: connection_id, biot_specs: specs},
         %State{status: :synchronizing, connection_id: connection_id} = state
       ) do
    :ok = Intents.replace(specs)

    case send_message(
           state.socket,
           %Message.Synchronized{connection_id: connection_id},
           state.version
         ) do
      :ok -> %{state | status: :ready, backoff_ms: state.backoff_min_ms}
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp handle_message(%Message.Desired{biot_spec: spec}, %State{status: :ready} = state) do
    :ok = Intents.put(spec)
    state
  end

  defp handle_message(%Message.Diagnostic{} = request, %State{status: :ready} = state) do
    result =
      case Diagnostics.fetch(request.diagnostic_id, request.max_bytes) do
        {:ok, value} -> value
        :not_found -> :not_found
      end

    message = %Message.DiagnosticResult{request_id: request.request_id, result: result}

    case send_message(state.socket, message, state.version) do
      :ok -> state
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp handle_message(%Message.Heartbeat{challenge: challenge}, state) do
    case send_message(
           state.socket,
           %Message.HeartbeatResponse{challenge: challenge},
           state.version
         ) do
      :ok -> state
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp handle_message(%Message.HeartbeatResponse{challenge: response}, state) do
    if Liveness.response_matches?(state.heartbeat_challenge, response),
      do: %{state | heartbeat_challenge: nil},
      else: state
  end

  defp handle_message(_message, state), do: disconnect(state, :unexpected_message)

  defp activate(%State{socket: nil}), do: :ok
  defp activate(%State{socket: socket}), do: :ssl.setopts(socket, active: :once)

  defp disconnect(%State{socket: socket} = state, reason) when not is_nil(socket) do
    :ssl.close(socket)
    disconnect(%{state | socket: nil}, reason)
  end

  defp disconnect(state, reason) do
    Logger.info("node control connection disconnected: #{inspect(reason)}")
    token = make_ref()
    Process.send_after(self(), {:reconnect, token}, state.backoff_ms)

    %{
      state
      | status: :disconnected,
        socket: nil,
        buffer: <<>>,
        version: nil,
        connection_id: nil,
        heartbeat_challenge: nil,
        reconnect_token: token,
        backoff_ms: min(state.backoff_ms * 2, state.backoff_max_ms)
    }
  end

  defp build_state(options) do
    backoff_min = option(options, :reconnect_backoff_min_ms, 250)

    %State{
      server_host: option(options, :server_host, nil),
      server_port: option(options, :server_port, nil),
      server_fingerprint: option(options, :server_fingerprint, nil),
      registration_id: registration_id(option(options, :registration_id, nil)),
      tls: option(options, :tls, nil),
      max_frame_bytes: option(options, :max_frame_bytes, 1_000_000),
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

  defp random_token, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp fingerprints_match?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp fingerprints_match?(_left, _right), do: false
end
