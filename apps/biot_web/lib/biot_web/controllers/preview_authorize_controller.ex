defmodule BiotWeb.PreviewAuthorizeController do
  @moduledoc "Starts the control-host side of a preview login handoff."

  use BiotWeb, :controller

  alias Biot.Server.PreviewHandoff
  alias Biot.Server.Publications
  alias BiotWeb.Params
  alias BiotWeb.PreviewPaths

  @spec authorize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authorize(conn, params) do
    with {:ok, {hostname, challenge, return_path}} <- Params.preview_authorize(params),
         {:ok, authentication} <- live_authentication(conn),
         {:ok, code} <- PreviewHandoff.begin(authentication, hostname, challenge, return_path) do
      redirect(conn, external: callback_url(hostname, code))
    else
      {:error, {:invalid_input, _fields}} -> failure(conn, :bad_request, "Bad request")
      {:error, :unauthenticated} -> redirect_to_login(conn)
      {:error, :forbidden} -> failure(conn, :forbidden, "Forbidden")
      {:error, :not_found} -> failure(conn, :not_found, "Not found")
    end
  end

  defp live_authentication(%{assigns: %{authentication: nil}}), do: {:error, :unauthenticated}

  defp live_authentication(%{assigns: %{authentication: authentication}}),
    do: {:ok, authentication}

  defp callback_url(hostname, code) do
    Publications.url(hostname) <> PreviewPaths.callback() <> "?code=" <> URI.encode(code)
  end

  defp redirect_to_login(conn) do
    return_path = conn.request_path <> query_suffix(conn.query_string)
    redirect(conn, to: "/login?" <> URI.encode_query(%{"return" => return_path}))
  end

  defp query_suffix(""), do: ""
  defp query_suffix(query_string), do: "?" <> query_string

  defp failure(conn, status, body), do: conn |> put_status(status) |> html(body)
end
