defmodule Biot.Server.Queries.Deployment do
  @moduledoc "Returns the server settings clients need to form public connections."

  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Principals
  alias Biot.Server.Queries.DeploymentView
  alias Biot.Server.Repo

  @spec get(Actor.t() | nil) :: {:ok, DeploymentView.t()} | {:error, CommandError.t()}
  def get(nil), do: {:error, :unauthenticated}

  def get(%Actor{} = actor) do
    with :ok <- Principals.require_enabled(Repo, actor) do
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
end
