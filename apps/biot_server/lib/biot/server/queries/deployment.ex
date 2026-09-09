defmodule Biot.Server.Queries.Deployment do
  @moduledoc "Returns the server settings clients need to form public connections."

  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Queries.DeploymentView

  @spec get(Actor.t() | nil) :: {:ok, DeploymentView.t()} | {:error, CommandError.t()}
  def get(nil), do: {:error, :unauthenticated}

  def get(%Actor{}) do
    {:ok,
     %DeploymentView{
       publication_domain: Application.fetch_env!(:biot_server, :publication_domain),
       ssh: %{
         host: Application.fetch_env!(:biot_server, :ssh_advertised_host),
         port: Application.fetch_env!(:biot_server, :ssh_port)
       }
     }}
  end
end
