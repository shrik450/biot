defmodule BiotWeb.Api.CredentialController do
  @moduledoc """
  Serves the listing and revocation of the actor's bearer credentials under `/api/credentials`.

  No route here creates a credential. Only the control account page does, because a credential
  must never mint another credential.
  """

  use BiotWeb, :api_controller

  alias Biot.Server.Credentials
  alias BiotWeb.Api.Json
  alias BiotWeb.Api.Response
  alias BiotWeb.Params

  def index(conn, _params) do
    with {:ok, credentials} <- Credentials.list(actor(conn)) do
      json(conn, Enum.map(credentials, &Json.encode/1))
    end
  end

  def revoke(conn, _params) do
    with {:ok, credential_id} <- Params.credential_id(conn.path_params),
         :ok <- Credentials.revoke(actor(conn), credential_id) do
      reply(conn, Response.build(:ok))
    end
  end
end
