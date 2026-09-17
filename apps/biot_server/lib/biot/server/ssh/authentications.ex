defmodule Biot.Server.Ssh.Authentications do
  @moduledoc """
  The duplicate-key Registry that ties one SSH connection to the key that authenticated it.

  The connection handler process owns both entries: one from its pid to the authentication, and one
  from the key ID to its pid. Removing a key finds every live connection under the key, and the
  entries vanish when the connection handler exits.
  """

  alias Biot.Protocol.SshKeyId
  alias Biot.Server.Authentication

  @registry __MODULE__.Registry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: Registry.start_link(keys: :duplicate, name: @registry)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_options), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "Records the calling connection handler's authentication under its key."
  @spec register(Authentication.t()) :: :ok
  def register(%Authentication{proof: {:ssh_key, %SshKeyId{} = key_id}} = authentication) do
    # The daemon may check the same key more than once in one handshake, so the connection
    # registers once and every later call is a no-op.
    case Registry.lookup(@registry, {:connection, self()}) do
      [] ->
        {:ok, _entry} = Registry.register(@registry, {:connection, self()}, authentication)
        {:ok, _entry} = Registry.register(@registry, {:key, key_id}, self())
        :ok

      _already_registered ->
        :ok
    end
  end

  @spec authentication(pid()) :: Authentication.t() | nil
  def authentication(connection) do
    case Registry.lookup(@registry, {:connection, connection}) do
      [{^connection, authentication} | _rest] -> authentication
      [] -> nil
    end
  end

  @spec connections(SshKeyId.t()) :: [pid()]
  def connections(%SshKeyId{} = key_id) do
    @registry
    |> Registry.lookup({:key, key_id})
    |> Enum.map(fn {pid, _value} -> pid end)
  end
end
