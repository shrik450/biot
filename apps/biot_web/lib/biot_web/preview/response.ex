defmodule BiotWeb.Preview.Response do
  @moduledoc """
  Parses the upstream HTTP/1.1 response head.

  `:erlang.decode_packet/3` owns the line and header tokenizing, so this module owns only what is
  Biot's: which headers survive and how the body is framed. The body itself is `Body`'s job.
  """

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @biot_cookie_prefix "__Host-biot_"

  defstruct [:status, :reason, :headers]

  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          status: pos_integer(),
          reason: String.t(),
          headers: [header()]
        }

  @doc """
  Parses one response head, bounded by `head_max` bytes.

  A malformed status line or header becomes `{:error, :malformed_response}`; an incomplete head is
  `:more`.
  """
  @spec parse_head(binary(), pos_integer()) :: {:ok, t(), binary()} | :more | {:error, term()}
  def parse_head(buffer, head_max) when is_binary(buffer) and is_integer(head_max) do
    with {:ok, {status, reason}, rest, consumed} <- status_line(buffer, head_max),
         {:ok, headers, rest} <- headers(rest, [], head_max - consumed) do
      {:ok, %__MODULE__{status: status, reason: reason, headers: headers}, rest}
    end
  end

  @doc "Removes hop-by-hop headers and any `Set-Cookie` naming a Biot cookie."
  @spec sanitize_headers([header()]) :: [header()]
  def sanitize_headers(headers) do
    connection_tokens = connection_tokens(headers)

    Enum.reject(headers, fn {name, value} ->
      name in @hop_by_hop or name in connection_tokens or
        (name == "set-cookie" and biot_cookie?(value))
    end)
  end

  @doc "How the response body is framed for `method`."
  @spec framing(t(), String.t()) :: :none | {:length, non_neg_integer()} | :chunked | :close
  def framing(%__MODULE__{status: status}, "HEAD") when status >= 200, do: :none
  def framing(%__MODULE__{status: status}, _method) when status in 100..199, do: :none
  def framing(%__MODULE__{status: status}, _method) when status in [204, 304], do: :none

  def framing(%__MODULE__{headers: headers}, _method) do
    if chunked?(headers) do
      :chunked
    else
      case content_length(headers) do
        {:ok, length} -> {:length, length}
        :error -> :close
      end
    end
  end

  defp status_line(buffer, head_max) do
    case :erlang.decode_packet(:http_bin, buffer, packet_size: head_max) do
      {:ok, {:http_response, _version, status, reason}, rest} ->
        {:ok, {status, reason}, rest, byte_size(buffer) - byte_size(rest)}

      {:ok, {:http_error, _line}, _rest} ->
        {:error, :malformed_response}

      {:more, _length} ->
        :more

      {:error, _reason} ->
        {:error, :malformed_response}
    end
  end

  # `remaining` is the cumulative budget left for the whole head, not a per-line limit, so an
  # application cannot evade the bound with many short headers.
  defp headers(buffer, acc, remaining) when remaining >= 0 do
    case :erlang.decode_packet(:httph_bin, buffer, packet_size: remaining) do
      {:ok, {:http_header, _length, name, _reserved, value}, rest} ->
        consumed = byte_size(buffer) - byte_size(rest)

        if consumed > remaining,
          do: {:error, :malformed_response},
          else: headers(rest, [{header_name(name), value} | acc], remaining - consumed)

      {:ok, :http_eoh, rest} ->
        # The terminating blank line is part of the head, so its two bytes count against the
        # budget like every header line.
        consumed = byte_size(buffer) - byte_size(rest)

        if consumed > remaining,
          do: {:error, :malformed_response},
          else: {:ok, Enum.reverse(acc), rest}

      {:more, _length} ->
        :more

      {:error, _reason} ->
        {:error, :malformed_response}
    end
  end

  defp headers(_buffer, _acc, _remaining), do: {:error, :malformed_response}

  defp header_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
  defp header_name(name) when is_binary(name), do: String.downcase(name)

  defp connection_tokens(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> name == "connection" end)
    |> Enum.flat_map(fn {_name, value} -> String.split(value, ",") end)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp biot_cookie?(value) do
    value
    |> String.split("=", parts: 2)
    |> hd()
    |> String.trim()
    |> String.starts_with?(@biot_cookie_prefix)
  end

  defp chunked?(headers) do
    Enum.any?(headers, fn {name, value} ->
      name == "transfer-encoding" and value |> String.downcase() |> String.contains?("chunked")
    end)
  end

  defp content_length(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> name == "content-length" end)
    |> Enum.map(fn {_name, value} -> value |> String.trim() |> Integer.parse() end)
    |> Enum.find_value(:error, fn
      {length, ""} when length >= 0 -> {:ok, length}
      _other -> nil
    end)
  end
end
