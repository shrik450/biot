defmodule BiotWeb.Api.SshKeyController do
  @moduledoc "Serves the listing, addition, and removal of the actor's SSH keys under `/api/ssh-keys`."

  use BiotWeb, :api_controller

  alias Biot.Server.SshKeys
  alias BiotWeb.Api.Json
  alias BiotWeb.Api.Response
  alias BiotWeb.Params

  def index(conn, _params) do
    with {:ok, keys} <- SshKeys.list(actor(conn)) do
      json(conn, Enum.map(keys, &Json.encode/1))
    end
  end

  def add(conn, _params) do
    with {:ok, {public_key, label}} <- Params.ssh_key(conn.body_params),
         {:ok, key} <- SshKeys.add(actor(conn), public_key, label) do
      reply(conn, Response.build(key))
    end
  end

  def remove(conn, _params) do
    with {:ok, key_id} <- Params.ssh_key_id(conn.path_params),
         :ok <- SshKeys.remove(actor(conn), key_id) do
      reply(conn, Response.build(:ok))
    end
  end
end
