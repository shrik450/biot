defmodule BiotWeb.TerminalController do
  @moduledoc "Authenticates and upgrades browser terminal requests to the WebSock handler."

  use BiotWeb, :controller

  import Plug.Conn

  alias Biot.Protocol.{BiotId, ShellRequest}
  alias Biot.Server.Sessions
  alias BiotWeb.ClientAddress
  alias BiotWeb.TerminalSocket

  @max_frame_size 65_536

  @spec upgrade(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upgrade(conn, %{"id" => id} = params) do
    with :ok <- exact_origin(conn),
         {:ok, client_address} <- client_address(conn),
         {:ok, authentication} <- control_authentication(conn),
         {:ok, biot_id} <- parse_biot_id(id),
         {:ok, request} <- shell_request(params) do
      conn
      |> WebSockAdapter.upgrade(
        TerminalSocket,
        %{
          authentication: authentication,
          biot_id: biot_id,
          client_address: client_address,
          request: request,
          stream: nil
        },
        timeout: :infinity,
        max_frame_size: @max_frame_size
      )
      |> halt()
    else
      {:error, :foreign_origin} -> reject(conn, 403, "foreign origin")
      {:error, :unauthenticated} -> reject(conn, 401, "authentication required")
      {:error, :invalid_id} -> reject(conn, 404, "biot not found")
      {:error, :invalid_request} -> reject(conn, 422, "invalid terminal request")
    end
  end

  defp exact_origin(conn) do
    control_origin = BiotWeb.Endpoint.url()

    case get_req_header(conn, "origin") do
      [^control_origin] -> :ok
      _origins -> {:error, :foreign_origin}
    end
  end

  defp client_address(conn) do
    %{address: peer_address} = get_peer_data(conn)
    trusted_edge_peers = Application.fetch_env!(:biot_web, :trusted_edge_peers)
    forwarded_for = get_req_header(conn, "x-forwarded-for")

    {:ok, ClientAddress.resolve(peer_address, trusted_edge_peers, forwarded_for)}
  end

  defp control_authentication(conn) do
    case get_session(conn, "token") do
      token when is_binary(token) ->
        case Sessions.control(token) do
          {:ok, authentication} -> {:ok, authentication}
          :error -> {:error, :unauthenticated}
        end

      _missing ->
        {:error, :unauthenticated}
    end
  end

  defp shell_request(params) do
    with {:ok, cols} <- positive_integer(Map.get(params, "cols")),
         {:ok, rows} <- positive_integer(Map.get(params, "rows")),
         {:ok, request} <-
           ShellRequest.parse(%{
             "term" => Map.get(params, "term"),
             "cols" => cols,
             "rows" => rows,
             "command" => nil
           }) do
      {:ok, request}
    else
      _error -> {:error, :invalid_request}
    end
  end

  defp parse_biot_id(id) do
    case BiotId.parse(id) do
      {:ok, biot_id} -> {:ok, biot_id}
      {:error, :invalid_format} -> {:error, :invalid_id}
    end
  end

  defp positive_integer(value) when is_integer(value) and value in 1..65_535, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..65_535 -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp positive_integer(_value), do: :error

  defp reject(conn, status, message), do: conn |> send_resp(status, message) |> halt()
end
