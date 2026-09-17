defmodule Biot.Server.Application do
  @moduledoc false

  use Application

  alias Biot.Protocol.Wire
  alias Biot.Server.Login.Settings

  @impl true
  def start(_type, _args) do
    Wire.check_frame_limit!(Application.fetch_env!(:biot_server, :max_frame_bytes))

    children =
      login_provider(Application.fetch_env!(:biot_server, :oidc)) ++
        [
          Biot.Server.Repo,
          Biot.Server.Migrator,
          Biot.Server.ExpirySweep,
          {Phoenix.PubSub, name: Biot.Server.PubSub},
          # Both startup reloads close the owners of the access they withdraw.
          Biot.Server.Access.Owners,
          Biot.Server.Access.AuthSweep,
          Biot.Server.Principals.Startup,
          # Startup needs the registry, while the listener must not accept a node before enrollment.
          {Registry, keys: :unique, name: Biot.Server.Control.Registry},
          Biot.Server.Nodes.Startup,
          Biot.Server.Streams.Pending,
          Biot.Server.Ssh.Authentications,
          Biot.Server.Control.Listener,
          Biot.Server.Ssh.Daemon
        ]

    opts = [strategy: :one_for_one, name: Biot.Server.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # A release always has settings; development and tests may run without a provider.
  defp login_provider(%Settings{issuer: issuer}) do
    [
      {Oidcc.ProviderConfiguration.Worker,
       %{
         issuer: issuer,
         name: Biot.Server.Login.Provider,
         backoff_type: :random_exponential,
         backoff_min: 100,
         backoff_max: 5_000
       }}
    ]
  end

  defp login_provider(nil), do: []
end
