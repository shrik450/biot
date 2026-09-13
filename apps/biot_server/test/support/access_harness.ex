defmodule Biot.Server.AccessHarness do
  @moduledoc """
  Real protocol peers and session owner processes for admission and closure tests.

  `ready_peer/4` connects to the real control listener with a node certificate and plays the
  node's side of the control protocol. A test therefore decides when the node refuses a stream,
  when it attaches one, and what it acknowledges. `Owner` is a session owner process that a test
  drives by message, and `Registered` is a process registered for closure with no stream.
  """

  import ExUnit.Assertions

  alias Biot.Protocol.{Frame, Message, Platform, Port, Wire}
  alias Biot.Server.Control.Listener
  alias Biot.Server.NodeConnections
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Node, Publication, ShellGrant, ViewGrant}
  alias Biot.Server.Sessions
  alias Biot.Server.TestFixtures

  @timeout 2_000

  defmodule Peer do
    @moduledoc "One connected fake node: its control socket and what it needs to attach streams."
    @enforce_keys [:socket, :connection_id, :node, :listener_port, :certificates, :index]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  @spec start_listener(map(), keyword()) :: :inet.port_number()
  def start_listener(certificates, handler_options \\ []) do
    options = [
      id: make_ref(),
      port: 0,
      tls: [
        certfile: certificates.server.cert,
        keyfile: certificates.server.key,
        cacertfile: certificates.ca
      ],
      handler_options:
        Keyword.merge(
          [
            handshake_timeout_ms: 1_000,
            heartbeat_interval_ms: 60_000,
            heartbeat_timeout_ms: 1_000
          ],
          handler_options
        )
    ]

    listener = ExUnit.Callbacks.start_supervised!(Listener.child_spec(options))
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    port
  end

  @doc "Inserts a node whose peer identity is the certificate at `index`."
  @spec node_row(pos_integer(), map(), non_neg_integer(), keyword()) :: Node.t()
  def node_row(number, certificates, index, options \\ []) do
    certificate = Enum.at(certificates.nodes, index)

    number
    |> TestFixtures.node(options)
    |> Ecto.Changeset.change(peer_identity: certificate.fingerprint)
    |> Repo.update!()
  end

  @doc """
  Connects as `node`, takes the snapshot, applies every revision in it, and reports synchronized.
  """
  @spec ready_peer(:inet.port_number(), map(), Node.t(), non_neg_integer()) :: Peer.t()
  def ready_peer(listener_port, certificates, %Node{} = node, index) do
    socket = connect(listener_port, certificates, index)
    {:ok, platform} = Platform.parse("aarch64-linux")

    send_message(
      socket,
      %Message.Hello{
        registration_id: node.registration,
        supported_protocol_versions: [1],
        platform: platform
      },
      :handshake
    )

    %Message.Connected{connection_id: connection_id} =
      await(socket, :handshake, Message.Connected, @timeout)

    %Message.SynchronizeBegin{count: count} = await(socket, 1, Message.SynchronizeBegin, @timeout)

    specs =
      for _index <- 1..count//1 do
        %Message.SynchronizeItem{biot_spec: spec} =
          await(socket, 1, Message.SynchronizeItem, @timeout)

        spec
      end

    %Message.SynchronizeEnd{} = await(socket, 1, Message.SynchronizeEnd, @timeout)

    # A real node applies each synchronized access revision before it reports synchronized.
    Enum.each(specs, fn spec ->
      send_message(
        socket,
        %Message.AccessApplied{
          biot_id: spec.execution.biot_id,
          access_revision: spec.access_revision
        },
        1
      )
    end)

    send_message(socket, %Message.Synchronized{connection_id: connection_id}, 1)

    wait_until(fn ->
      NodeConnections.current(node.id) == %{connection_id: connection_id, state: :ready}
    end)

    %Peer{
      socket: socket,
      connection_id: connection_id,
      node: node,
      listener_port: listener_port,
      certificates: certificates,
      index: index
    }
  end

  @spec await_open(Peer.t(), timeout()) :: Message.OpenStream.t()
  def await_open(%Peer{socket: socket}, timeout \\ @timeout),
    do: await(socket, 1, Message.OpenStream, timeout)

  @spec await_message(Peer.t(), module(), timeout()) :: struct()
  def await_message(%Peer{socket: socket}, module, timeout \\ @timeout),
    do: await(socket, 1, module, timeout)

  @doc "Fails if a message of `module` reaches the peer within `timeout`."
  @spec no_message(Peer.t(), module(), timeout()) :: :ok
  def no_message(%Peer{socket: socket}, module, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case receive_until(socket, 1, deadline, fn message ->
           match?(%{__struct__: ^module}, message)
         end) do
      {:ok, message} -> flunk("the peer received #{inspect(message)}")
      :timeout -> :ok
      :closed -> :ok
    end
  end

  @doc "Returns every message the peer receives until its control socket closes."
  @spec messages_until_closed(Peer.t(), timeout()) :: [struct()]
  def messages_until_closed(%Peer{socket: socket}, timeout \\ @timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_until_closed(socket, deadline, [])
  end

  @spec refuse(Peer.t(), Biot.Protocol.StreamId.t(), Biot.Protocol.StreamFailure.t()) :: :ok
  def refuse(%Peer{socket: socket}, stream_id, reason),
    do: send_message(socket, %Message.StreamFailed{stream_id: stream_id, reason: reason}, 1)

  @spec apply_access(Peer.t(), Biot.Protocol.BiotId.t(), pos_integer()) :: :ok
  def apply_access(%Peer{socket: socket}, biot_id, revision),
    do:
      send_message(
        socket,
        %Message.AccessApplied{biot_id: biot_id, access_revision: revision},
        1
      )

  @doc """
  Opens the node's stream connection for `stream_id` and waits for `attached`.

  After `attached` the server hands its end of this connection to the session owner, so the
  returned socket shows when the owner closes the stream.
  """
  @spec attach(Peer.t(), Biot.Protocol.StreamId.t()) :: :ssl.sslsocket()
  def attach(%Peer{} = peer, stream_id) do
    socket = connect(peer.listener_port, peer.certificates, peer.index)

    send_message(
      socket,
      %Message.Attach{
        registration_id: peer.node.registration,
        connection_id: peer.connection_id,
        stream_id: stream_id
      },
      :handshake
    )

    %Message.Attached{} = await(socket, :handshake, Message.Attached, @timeout)
    socket
  end

  @doc "True when the other end of a stream connection has closed it."
  @spec closed?(:ssl.sslsocket(), timeout()) :: boolean()
  def closed?(socket, timeout \\ @timeout), do: :ssl.recv(socket, 0, timeout) == {:error, :closed}

  @doc "The closure keys a process holds in the owner Registry."
  @spec registered_keys(pid()) :: [term()]
  def registered_keys(pid), do: Registry.keys(Biot.Server.Access.Owners.Registry, pid)

  @spec control(Biot.Server.Schema.Principal.t()) ::
          {String.t(), Biot.Server.Authentication.t()}
  def control(principal) do
    {:ok, token} = Sessions.start_control(principal.id)
    {:ok, authentication} = Sessions.control(token)
    {token, authentication}
  end

  @spec publication(Biot.Server.Schema.Biot.t(), Port.t(), Biot.Protocol.Hostname.t()) ::
          Publication.t()
  def publication(biot, port, hostname) do
    Repo.insert!(%Publication{biot_id: biot.id, port: port, hostname: hostname, state: :active})
  end

  @spec shell_grant(Biot.Server.Schema.Biot.t(), Biot.Server.Schema.Principal.t()) ::
          ShellGrant.t()
  def shell_grant(biot, principal),
    do: Repo.insert!(%ShellGrant{biot_id: biot.id, principal_id: principal.id})

  @spec view_grant(Biot.Server.Schema.Biot.t(), Port.t(), Biot.Server.Schema.Principal.t()) ::
          ViewGrant.t()
  def view_grant(biot, port, principal),
    do: Repo.insert!(%ViewGrant{biot_id: biot.id, port: port, principal_id: principal.id})

  @spec wait_until((-> term()), timeout()) :: term()
  def wait_until(function, timeout \\ @timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until_deadline(function, deadline)
  end

  @spec pause(non_neg_integer()) :: :ok
  def pause(milliseconds) do
    receive do
    after
      milliseconds -> :ok
    end
  end

  defp wait_until_deadline(function, deadline) do
    case function.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("condition did not hold within the deadline"),
          else: pause(10)

        wait_until_deadline(function, deadline)

      value ->
        value
    end
  end

  defp connect(port, certificates, index) do
    certificate = Enum.at(certificates.nodes, index)

    options = [
      verify: :verify_peer,
      cacertfile: certificates.ca,
      certfile: certificate.cert,
      keyfile: certificate.key,
      active: false,
      mode: :binary,
      packet: :raw,
      server_name_indication: :disable
    ]

    {:ok, socket} = :ssl.connect(~c"127.0.0.1", port, options, @timeout)
    socket
  end

  defp send_message(socket, message, context) do
    {:ok, encoded} = Wire.encode(message, context)
    :ok = :ssl.send(socket, Frame.encode(encoded))
  end

  defp await(socket, context, module, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case receive_until(socket, context, deadline, &match?(%{__struct__: ^module}, &1)) do
      {:ok, message} -> message
      :timeout -> flunk("the peer received no #{inspect(module)} within #{timeout} ms")
      :closed -> flunk("the peer's connection closed before a #{inspect(module)} arrived")
    end
  end

  # Skips every message that does not match, and answers heartbeats as a node must.
  defp receive_until(socket, context, deadline, wanted?) do
    case read_frame(socket, context, deadline) do
      {:ok, %Message.Heartbeat{challenge: challenge}} ->
        send_message(socket, %Message.HeartbeatResponse{challenge: challenge}, context)
        receive_until(socket, context, deadline, wanted?)

      {:ok, message} ->
        if wanted?.(message),
          do: {:ok, message},
          else: receive_until(socket, context, deadline, wanted?)

      {:error, :timeout} ->
        :timeout

      {:error, :closed} ->
        :closed
    end
  end

  defp collect_until_closed(socket, deadline, messages) do
    case read_frame(socket, 1, deadline) do
      {:ok, message} -> collect_until_closed(socket, deadline, [message | messages])
      {:error, :closed} -> Enum.reverse(messages)
      {:error, :timeout} -> flunk("the peer's connection stayed open: #{inspect(messages)}")
    end
  end

  defp read_frame(socket, context, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    with {:ok, <<size::unsigned-big-32>>} <- :ssl.recv(socket, 4, remaining),
         {:ok, payload} <- :ssl.recv(socket, size, remaining) do
      {:ok, message} = Wire.decode(payload, context)
      {:ok, message}
    end
  end

  defmodule Owner do
    @moduledoc """
    A session owner process that a test drives by message.

    `admit/2` runs an admission in the owner. While it holds a stream, the owner passes every
    message it receives through `Access.Admission.handle_owner_message/2`, as a real owner's
    receive loop does. When a policy close arrives, it first runs `probe` so the test learns what
    the owner could read at that moment. Between admissions it reads only harness messages, so a
    stale message stays in its mailbox as it would in a real process.
    """

    import ExUnit.Assertions

    alias Biot.Server.Access.Admission
    alias Biot.Server.Streams.Stream

    @spec start((-> term())) :: pid()
    def start(probe \\ fn -> nil end) do
      parent = self()
      spawn_link(fn -> idle(parent, probe) end)
    end

    @doc "Starts an admission; the result arrives as `{:admitted, owner, result}`."
    @spec admit(pid(), (-> {:ok, Stream.t()} | {:error, atom()})) :: :ok
    def admit(owner, admission) do
      send(owner, {:harness_admit, admission})
      :ok
    end

    @spec await_admitted(pid(), timeout()) :: {:ok, Stream.t()} | {:error, atom()}
    def await_admitted(owner, timeout \\ 10_000) do
      assert_receive {:admitted, ^owner, result}, timeout
      result
    end

    @doc "Makes the owner close its stream for its own reason, as a client disconnect would."
    @spec close(pid()) :: :ok
    def close(owner) do
      send(owner, :harness_close)
      :ok
    end

    defp idle(parent, probe) do
      receive do
        {:harness_admit, admission} ->
          case admission.() do
            {:ok, %Stream{} = stream} = result ->
              send(parent, {:admitted, self(), result})
              serve(parent, probe, stream)

            {:error, _reason} = result ->
              send(parent, {:admitted, self(), result})
              idle(parent, probe)
          end
      end
    end

    defp serve(parent, probe, stream) do
      receive do
        :harness_close ->
          :ok = Admission.close(stream)
          send(parent, {:owner_closed, self(), :by_owner, nil})
          idle(parent, probe)

        message ->
          observed = if message == {:biot_access, :close}, do: probe.()

          case Admission.handle_owner_message(stream, message) do
            {:closed, reason} ->
              send(parent, {:owner_closed, self(), reason, observed})
              idle(parent, probe)

            :ignored ->
              serve(parent, probe, stream)
          end
      end
    end
  end

  defmodule Registered do
    @moduledoc """
    A process registered for closure the way admission registers an owner, with no stream.

    It stays registered and reports every close it receives, with what `probe` reads at that
    moment.
    """

    import ExUnit.Assertions

    alias Biot.Server.Access.Owners
    alias Biot.Server.Authentication.Validity

    @spec start(Biot.Protocol.BiotId.t(), Biot.Server.Authentication.t(), (-> term())) :: pid()
    def start(biot_id, authentication, probe \\ fn -> nil end) do
      parent = self()

      pid =
        spawn_link(fn ->
          :ok =
            Owners.register(
              biot_id,
              authentication.actor.principal_id,
              Validity.proof_keys(authentication)
            )

          send(parent, {:registered, self()})
          loop(parent, probe)
        end)

      assert_receive {:registered, ^pid}, 2_000
      pid
    end

    defp loop(parent, probe) do
      receive do
        {:biot_access, :close} ->
          send(parent, {:closed, self(), probe.()})
          loop(parent, probe)
      end
    end
  end
end
