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

  @impl true
  def init(_options) do
    case Application.get_env(:biot_server, :ssh_host_key_file) do
      nil -> :ignore
      path -> start(path)
    end
  end

  defp start(path) do
    with {:ok, pinned} <- KeyCallback.validate(path),
         {:ok, port} <- port() do
      case :ssh.daemon(port, daemon_options(pinned)) do
        {:ok, daemon} -> {:ok, %{daemon: daemon}}
        {:error, reason} -> {:stop, {:ssh_daemon_failed, reason}}
      end
    else
      {:error, reason} -> {:stop, reason}
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
      auth_methods: ~c"publickey",
      subsystems: [],
      ssh_cli: {Channel, []},
      # The decoded key set is pinned here for the daemon's life: it stays out of any globally
      # readable term, and replacing the file cannot change the key served to new clients.
      key_cb: {KeyCallback, [pinned: pinned]},
      preferred_algorithms: [public_key: pinned.algorithms]
    ]
  end
end
