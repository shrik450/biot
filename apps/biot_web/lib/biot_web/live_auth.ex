defmodule BiotWeb.LiveAuth do
  @moduledoc "Authenticates and owns the lifetime of control-session LiveViews."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Biot.Protocol.SameOriginPath
  alias Biot.Server.Access.Owners
  alias Biot.Server.Authentication
  alias Biot.Server.Sessions

  @spec on_mount(:authenticated, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:authenticated, _params, session, socket) do
    case session["token"] do
      token when is_binary(token) -> authenticate(token, socket)
      _missing -> redirect_to_login(socket)
    end
  end

  defp authenticate(token, socket) do
    case Sessions.control(token) do
      {:ok, %Authentication{} = authentication} ->
        socket =
          socket
          |> assign(:authentication, authentication)
          |> assign(:actor, authentication.actor)

        if connected?(socket) do
          {:cont, register_connection(socket, authentication)}
        else
          {:cont, socket}
        end

      :error ->
        redirect_to_login(socket)
    end
  end

  defp register_connection(socket, %Authentication{} = authentication) do
    :ok =
      Owners.register_connection(authentication)

    socket
    |> assign(:live_auth_return_path, connect_return_path(socket))
    |> attach_hook(:biot_live_auth_path, :handle_params, &track_return_path/3)
    |> attach_hook(:biot_live_auth_events, :handle_event, &check_event/3)
    |> attach_hook(:biot_live_auth_messages, :handle_info, &check_message/2)
    |> schedule_expiry(authentication)
    |> schedule_validity_check()
  end

  defp track_return_path(_params, uri, socket) do
    case same_origin_return_path(uri) do
      nil -> {:cont, socket}
      path -> {:cont, assign(socket, :live_auth_return_path, path)}
    end
  end

  defp schedule_expiry(socket, %Authentication{} = authentication) do
    case Sessions.expires_at(authentication) do
      nil ->
        socket

      %DateTime{} = expires_at ->
        delay = max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 0)
        Process.send_after(self(), :biot_live_auth_expired, delay)
        socket
    end
  end

  defp schedule_validity_check(socket) do
    case Application.get_env(:biot_server, :auth_check_interval_ms) do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 ->
        Process.send_after(self(), :biot_live_auth_check, interval_ms)
        socket

      _disabled ->
        socket
    end
  end

  defp check_event(_event, _params, socket) do
    case live_authentication(socket) do
      {:ok, _authentication} -> {:cont, socket}
      :error -> {:halt, close_connection(socket)}
    end
  end

  defp check_message(:biot_live_auth_expired, socket),
    do: {:halt, close_connection(socket)}

  defp check_message(:biot_live_auth_check, socket) do
    case live_authentication(socket) do
      {:ok, _authentication} ->
        {:halt, schedule_validity_check(socket)}

      :error ->
        {:halt, close_connection(socket)}
    end
  end

  defp check_message({:biot_access, :close}, socket),
    do: {:halt, close_connection(socket)}

  defp check_message(_message, socket) do
    case live_authentication(socket) do
      {:ok, _authentication} -> {:cont, socket}
      :error -> {:halt, close_connection(socket)}
    end
  end

  defp live_authentication(%{assigns: %{authentication: %Authentication{} = authentication}}) do
    case Sessions.valid?(authentication) do
      {:ok, _expires_at} -> {:ok, authentication}
      :error -> :error
    end
  end

  defp live_authentication(_socket), do: :error

  defp close_connection(socket) do
    _ = Owners.unregister()
    redirect(socket, to: login_path(socket))
  end

  defp redirect_to_login(socket) do
    socket = assign(socket, :live_auth_return_path, connect_return_path(socket))
    {:halt, close_connection(socket)}
  end

  defp login_path(socket) do
    return_path = Map.get(socket.assigns, :live_auth_return_path, "/")
    "/login?return=" <> URI.encode_www_form(return_path)
  end

  defp connect_return_path(socket) do
    socket
    |> get_connect_info(:uri)
    |> request_return_path()
    |> Kernel.||("/")
  end

  defp request_return_path(%URI{path: path, query: query}), do: path_and_query(path, query)

  defp request_return_path(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{} = parsed -> request_return_path(parsed)
    end
  end

  defp request_return_path(_uri), do: nil

  defp same_origin_return_path(%URI{scheme: nil, host: nil, path: path, query: query}),
    do: path_and_query(path, query)

  defp same_origin_return_path(%URI{} = uri) do
    endpoint = URI.parse(BiotWeb.Endpoint.url())

    if same_origin?(uri, endpoint),
      do: path_and_query(uri.path || "/", uri.query),
      else: nil
  end

  defp same_origin_return_path(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: nil, host: nil, path: path, query: query} -> path_and_query(path, query)
      %URI{} = parsed -> same_origin_return_path(parsed)
    end
  end

  defp same_origin_return_path(_uri), do: nil

  defp same_origin?(
         %URI{scheme: scheme, host: host} = uri,
         %URI{scheme: endpoint_scheme, host: endpoint_host} = endpoint
       )
       when is_binary(scheme) and is_binary(host) and is_binary(endpoint_scheme) and
              is_binary(endpoint_host) do
    String.downcase(scheme) == String.downcase(endpoint_scheme) and
      String.downcase(host) == String.downcase(endpoint_host) and
      effective_port(uri) == effective_port(endpoint)
  end

  defp same_origin?(_uri, _endpoint), do: false

  defp effective_port(%URI{port: port}) when is_integer(port), do: port

  defp effective_port(%URI{scheme: scheme}), do: URI.default_port(scheme)

  defp path_and_query(path, query) when is_binary(path) and path != "" do
    value =
      case query do
        query when query in [nil, ""] -> path
        query -> path <> "?" <> query
      end

    case SameOriginPath.parse(value) do
      {:ok, %SameOriginPath{value: value}} -> value
      {:error, :invalid_format} -> nil
    end
  end

  defp path_and_query(_path, _query), do: nil
end
