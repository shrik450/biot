defmodule Biot.Server.Ssh.Daemon do
  @moduledoc """
  The server's SSH daemon as a supervised child.

  It offers public key authentication only, no subsystems, and no forwarding, and it gives each
  session channel to `Biot.Server.Ssh.Channel`. The daemon stops with `:ssh.stop_daemon/1`, which
  is the daemon's own stop; `:ssh.close/1` is only for closing one live connection.
  """

  use GenServer

  alias Biot.Server.Ssh.{Channel, KeyCallback}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc "Returns the host keys pinned by the running daemon, or an empty list when SSH is disabled."
  @spec host_keys() :: [map()]
  def host_keys do
    case Process.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :host_keys)
    end
  catch
    :exit, _reason -> []
  end

  @impl true
  def init(_options) do
    case Application.get_env(:biot_server, :ssh_host_key_file) do
      nil -> :ignore
      path -> start(path)
    end
  end

  @impl true
  def handle_call(:host_keys, _from, state), do: {:reply, state.pinned.host_keys, state}

  defp start(path) do
    case KeyCallback.validate(path) do
      {:ok, pinned} -> start_daemon(pinned)
      {:error, reason} -> {:stop, KeyCallback.message(path, reason)}
    end
  end

  defp start_daemon(pinned) do
    case port() do
      {:ok, port} ->
        case :ssh.daemon(port, daemon_options(pinned)) do
          {:ok, daemon} -> {:ok, %{daemon: daemon, pinned: pinned}}
          {:error, reason} -> {:stop, {:ssh_daemon_failed, reason}}
        end

      {:error, :ssh_port_not_configured} ->
        {:stop,
         "a host key file is configured but BIOT_SSH_PORT is missing or not a positive port"}
    end
  end

  @impl true
  def terminate(_reason, %{daemon: daemon}) do
    _ = :ssh.stop_daemon(daemon)
    :ok
  end

  defp port do
    case Application.fetch_env(:biot_server, :ssh_port) do
      {:ok, port} when is_integer(port) and port > 0 -> {:ok, port}
      _unset -> {:error, :ssh_port_not_configured}
    end
  end

  defp daemon_options(pinned) do
    [
      # Public keys only. OTP also offers keyboard-interactive and password by default; this daemon
      # has no password source, so those methods could never succeed and are not offered.
      auth_methods: ~c"publickey",
      # No subsystems. OTP enables sftp by default, and that subsystem runs as a channel in this
      # daemon on the server host, so it would give a collaborator file access to the server
      # itself rather than to the Biot a shell grant names.
      subsystems: [],
      # No port forwarding, in either direction. Without these a client could ask the daemon to
      # forward a TCP port and reach the node's private network through what is supposed to be a
      # shell grant, so a terminal would also be a route.
      tcpip_tunnel_in: false,
      tcpip_tunnel_out: false,
      ssh_cli: {Channel, []},
      # The decoded key set is pinned here for the daemon's life: it stays out of any globally
      # readable term, and replacing the file cannot change the key served to new clients.
      key_cb: {KeyCallback, [pinned: pinned]},
      preferred_algorithms: [public_key: pinned.algorithms]
    ]
  end
end
