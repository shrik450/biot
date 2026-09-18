defmodule BiotWeb.Preview.Proxy do
  @moduledoc """
  The imperative shell of the preview proxy.

  One call owns one port stream from admission to close. It authenticates the caller, opens the
  stream through `Access.open_preview/2`, writes the rewritten request, streams the body up,
  parses and streams the response down, and renders a small Biot page for a failure that happens
  before any response byte is committed.
  """

  import Plug.Conn

  alias Biot.Protocol.{Digest, Hostname}
  alias Biot.Server.Access
  alias Biot.Server.Publications
  alias Biot.Server.Repo
  alias Biot.Server.Streams
  alias Biot.Server.Tokens
  alias BiotWeb.Cookies
  alias BiotWeb.Preview.{Body, Callback, Identity, Limits, Page, Request, Response, Upgrade}
  alias BiotWeb.PreviewPaths

  @spec call(Plug.Conn.t(), Hostname.t()) :: Plug.Conn.t()
  def call(conn, hostname) do
    conn =
      if String.starts_with?(conn.request_path, "/__biot/") do
        if conn.request_path == PreviewPaths.callback(),
          do: Callback.call(conn, hostname),
          else: Page.render(conn, :not_found)
      else
        proxy(conn, hostname)
      end

    halt(conn)
  end

  @spec unknown_host(Plug.Conn.t()) :: Plug.Conn.t()
  def unknown_host(conn), do: conn |> Page.render(:not_found) |> halt()

  defp proxy(conn, hostname) do
    conn = fetch_cookies(conn)

    case ensure_published(hostname) do
      :ok ->
        if Upgrade.upgrade?(conn), do: Upgrade.call(conn, hostname), else: plain(conn, hostname)

      {:error, :not_found} ->
        Page.render(conn, :not_found)
    end
  end

  defp plain(conn, hostname) do
    case Identity.resolve(conn, hostname) do
      {:ok, authentication, _source} -> forward(conn, hostname, authentication)
      :handoff -> begin_handoff(conn, hostname)
      {:error, reason} -> Page.render(conn, reason)
    end
  end

  defp ensure_published(hostname) do
    case Publications.active_by_hostname(Repo, hostname) do
      nil -> {:error, :not_found}
      _publication -> :ok
    end
  end

  defp begin_handoff(conn, hostname) do
    {challenge, digest} = Tokens.mint()

    query =
      URI.encode_query(%{
        "host" => Hostname.to_string(hostname),
        "challenge" => Digest.to_string(digest),
        "return" => return_path(conn)
      })

    conn
    |> put_resp_cookie(Cookies.handoff_name(), challenge, Cookies.handoff_options())
    |> put_resp_header("location", BiotWeb.Endpoint.url() <> "/preview/authorize?" <> query)
    |> send_resp(302, "")
  end

  defp return_path(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end

  defp forward(conn, hostname, authentication) do
    case Access.open_preview(authentication, hostname) do
      {:ok, stream} -> exchange(conn, stream, authentication)
      {:error, reason} -> Page.render(conn, admission_error(reason))
    end
  end

  defp exchange(conn, stream, authentication) do
    head = Request.head(conn, Identity.headers(authentication))

    case stream_request(conn, stream, head) do
      :ok ->
        read_head(conn, stream, <<>>)

      {:error, reason} ->
        _ = Access.close(stream)
        Page.render(conn, request_error(reason))
    end
  end

  defp stream_request(conn, stream, head) do
    with :ok <- write(stream, head) do
      stream_request_body(conn, stream, 0)
    end
  end

  defp stream_request_body(conn, stream, sent) do
    options = [length: Limits.request_chunk_bytes(), read_length: Limits.request_chunk_bytes()]

    case read_body(conn, options) do
      {:ok, data, _conn} -> finish_request_body(stream, data, sent)
      {:more, data, conn} -> more_request_body(conn, stream, data, sent)
      {:error, _reason} -> {:error, :request_failed}
    end
  end

  defp finish_request_body(stream, data, sent) do
    if sent + byte_size(data) > Limits.request_max_bytes(),
      do: {:error, :request_too_large},
      else: write(stream, data)
  end

  defp more_request_body(conn, stream, data, sent) do
    next = sent + byte_size(data)

    if next > Limits.request_max_bytes() do
      {:error, :request_too_large}
    else
      with :ok <- write(stream, data), do: stream_request_body(conn, stream, next)
    end
  end

  # A stream write is the only place the upstream can vanish mid-request.
  defp write(stream, data) do
    case Streams.write(stream, data) do
      :ok -> :ok
      {:error, _reason} -> {:error, :stream_lost}
    end
  end

  defp read_head(conn, stream, buffer) do
    case Response.parse_head(buffer, Limits.head_max_bytes()) do
      # An informational response is not the final one; drop it and read the next head.
      {:ok, %Response{status: status}, rest} when status in 100..199 ->
        read_head(conn, stream, rest)

      {:ok, response, rest} ->
        send_response(conn, stream, response, rest)

      :more ->
        await_head(conn, stream, buffer)

      # Bytes that are not an HTTP response are the application failing to answer, not a stream it
      # lost, so the page must send the person to the application.
      {:error, :malformed_response} ->
        _ = Access.close(stream)
        Page.render(conn, :invalid_response)
    end
  end

  defp await_head(conn, stream, buffer) do
    case await_stream(stream) do
      {:ok, events, stream} ->
        consume_head(events, conn, stream, buffer)

      # Closing before a head arrives is that same failure to answer, not a lost stream.
      :closed ->
        _ = Access.close(stream)
        Page.render(conn, :invalid_response)
    end
  end

  defp consume_head(events, conn, stream, buffer) do
    case append_data(events, buffer) do
      {:ok, buffer} ->
        read_head(conn, stream, buffer)

      # Closing part-way through a head is that same failure to answer.
      :closed ->
        _ = Access.close(stream)
        Page.render(conn, :invalid_response)

      {:error, :lost} ->
        _ = Access.close(stream)
        Page.render(conn, :agent_unreachable)
    end
  end

  defp append_data([], buffer), do: {:ok, buffer}
  defp append_data([{:data, data} | rest], buffer), do: append_data(rest, buffer <> data)
  defp append_data([:closed | _rest], _buffer), do: :closed
  defp append_data([:lost | _rest], _buffer), do: {:error, :lost}

  defp send_response(conn, stream, response, leftover) do
    headers =
      response.headers
      |> Response.sanitize_headers()
      # Biot re-frames every body, so the upstream length is never the length the client sees.
      |> Enum.reject(fn {name, _value} -> name == "content-length" end)

    case Response.framing(response, conn.method) do
      :none ->
        conn = put_headers(conn, headers)
        _ = Access.close(stream)
        send_resp(conn, response.status, "")

      framing ->
        conn = conn |> put_headers(headers) |> send_chunked(response.status)
        pump(conn, stream, framing_body(framing), leftover)
    end
  end

  defp pump(conn, stream, body, buffer) do
    case Body.push(body, buffer) do
      {:ok, chunks, body} ->
        case emit(conn, chunks) do
          {:ok, conn} ->
            await_body(conn, stream, body)

          {:error, conn} ->
            _ = Access.close(stream)
            conn
        end

      {:done, chunks, _body} ->
        {:ok, conn} = emit(conn, chunks)
        _ = Access.close(stream)
        conn

      {:error, _reason} ->
        _ = Access.close(stream)
        conn
    end
  end

  defp await_body(conn, stream, body) do
    case await_stream(stream) do
      {:ok, events, stream} ->
        consume_body(events, conn, stream, body)

      :closed ->
        _ = Access.close(stream)
        conn
    end
  end

  defp consume_body([], conn, stream, body), do: await_body(conn, stream, body)

  defp consume_body([{:data, data} | rest], conn, stream, body) do
    case Body.push(body, data) do
      {:ok, chunks, body} ->
        case emit(conn, chunks) do
          {:ok, conn} ->
            consume_body(rest, conn, stream, body)

          {:error, conn} ->
            _ = Access.close(stream)
            conn
        end

      {:done, chunks, _body} ->
        {:ok, conn} = emit(conn, chunks)
        _ = Access.close(stream)
        conn

      {:error, _reason} ->
        _ = Access.close(stream)
        conn
    end
  end

  defp consume_body([:closed | _rest], conn, stream, _body) do
    _ = Access.close(stream)
    conn
  end

  defp consume_body([:lost | _rest], conn, stream, _body) do
    _ = Access.close(stream)
    conn
  end

  # One read is armed at a time, so the node cannot send the next chunk until this owner asks.
  defp await_stream(stream) do
    case Streams.ask(stream) do
      :ok -> await_message(stream)
      {:error, _reason} -> :closed
    end
  end

  defp await_message(stream) do
    receive do
      message ->
        case Access.handle_owner_message(stream, message) do
          {:closed, _reason} ->
            :closed

          :ignored ->
            case Streams.stream(stream, message) do
              :unknown -> await_message(stream)
              {events, stream} -> {:ok, events, stream}
            end
        end
    after
      Limits.exchange_timeout_ms() -> :closed
    end
  end

  defp emit(conn, chunks) do
    Enum.reduce_while(chunks, {:ok, conn}, fn chunk, {:ok, conn} ->
      case chunk(conn, chunk) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _reason} -> {:halt, {:error, conn}}
      end
    end)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
  end

  defp framing_body({:length, length}), do: Body.length(length)
  defp framing_body(:chunked), do: Body.chunked(Limits.head_max_bytes())
  defp framing_body(:close), do: Body.close()

  defp admission_error(:unauthenticated), do: :unauthenticated
  defp admission_error(:not_found), do: :not_found
  defp admission_error(:forbidden), do: :forbidden
  defp admission_error(:node_unavailable), do: :node_unavailable
  defp admission_error(:agent_unreachable), do: :agent_unreachable
  defp admission_error(:port_not_listening), do: :port_not_listening
  defp admission_error(:too_many_streams), do: :too_many_streams
  defp admission_error(:timeout), do: :timeout

  defp request_error(:request_too_large), do: :too_large
  defp request_error(:stream_lost), do: :agent_unreachable
  defp request_error(:request_failed), do: :agent_unreachable
end
