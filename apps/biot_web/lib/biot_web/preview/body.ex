defmodule BiotWeb.Preview.Body do
  @moduledoc """
  Pure incremental body framing for the preview proxy's upstream response.

  It owns what is Biot's, not HTTP's line parsing: how many bytes remain for a `Content-Length`
  body, how to walk a chunked body, and that anything after the declared end is a protocol error.
  The caller feeds it the raw bytes it receives and forwards each emitted chunk, so the body is
  never buffered whole.
  """

  # A chunk-size line or a trailer line is small. Bound each so a hostile upstream cannot make
  # the buffer grow without limit before a newline arrives.
  @max_line_bytes 8_192

  defstruct mode: :close,
            remaining: 0,
            phase: :size,
            buffer: <<>>,
            trailer_max: 8_192,
            trailer_bytes: 0

  @type mode :: :length | :chunked | :close
  @type phase :: :size | :data | :data_crlf | :trailers

  @type t :: %__MODULE__{
          mode: mode(),
          remaining: non_neg_integer(),
          phase: phase(),
          buffer: binary(),
          trailer_max: pos_integer(),
          trailer_bytes: non_neg_integer()
        }

  @spec length(non_neg_integer()) :: t()
  def length(size), do: %__MODULE__{mode: :length, remaining: size}

  @doc "A chunked body whose whole trailer section is bounded by `trailer_max` bytes."
  @spec chunked(pos_integer()) :: t()
  def chunked(trailer_max) when is_integer(trailer_max) and trailer_max > 0,
    do: %__MODULE__{mode: :chunked, phase: :size, trailer_max: trailer_max}

  @spec close() :: t()
  def close, do: %__MODULE__{mode: :close}

  @spec push(t(), binary()) ::
          {:ok, [binary()], t()} | {:done, [binary()], t()} | {:error, term()}
  def push(%__MODULE__{mode: :length, remaining: 0} = body, <<>>), do: {:done, [], body}
  def push(%__MODULE__{mode: :length, remaining: 0}, _data), do: {:error, :unexpected_bytes}

  def push(%__MODULE__{mode: :length, remaining: remaining} = body, data) do
    take = min(remaining, byte_size(data))
    <<emit::binary-size(^take), rest::binary>> = data
    body = %{body | remaining: remaining - take}

    cond do
      body.remaining > 0 -> {:ok, [emit], body}
      rest == <<>> -> {:done, [emit], body}
      true -> {:error, :unexpected_bytes}
    end
  end

  def push(%__MODULE__{mode: :close} = body, data), do: {:ok, [data], body}

  def push(%__MODULE__{mode: :chunked} = body, data) do
    parse_chunked(%{body | buffer: body.buffer <> data}, [])
  end

  defp parse_chunked(%__MODULE__{phase: :size} = body, emits), do: chunk_size(body, emits)
  defp parse_chunked(%__MODULE__{phase: :data} = body, emits), do: chunk_data(body, emits)

  defp parse_chunked(%__MODULE__{phase: :data_crlf} = body, emits),
    do: chunk_data_crlf(body, emits)

  defp parse_chunked(%__MODULE__{phase: :trailers} = body, emits),
    do: chunk_trailers(body, emits)

  defp chunk_size(%__MODULE__{buffer: buffer} = body, emits) do
    case :binary.match(buffer, "\r\n") do
      :nomatch ->
        if byte_size(buffer) > @max_line_bytes,
          do: {:error, :chunk_size_too_long},
          else: {:ok, Enum.reverse(emits), body}

      {position, 2} ->
        line = binary_part(buffer, 0, position)
        rest = binary_part(buffer, position + 2, byte_size(buffer) - position - 2)

        case parse_hex_size(line) do
          {:ok, 0} ->
            parse_chunked(%{body | buffer: rest, phase: :trailers}, emits)

          {:ok, size} ->
            parse_chunked(%{body | buffer: rest, phase: :data, remaining: size}, emits)

          :error ->
            {:error, :invalid_chunk_size}
        end
    end
  end

  defp chunk_data(%__MODULE__{buffer: buffer, remaining: remaining} = body, emits) do
    take = min(remaining, byte_size(buffer))

    if take == 0 do
      {:ok, Enum.reverse(emits), body}
    else
      emit = binary_part(buffer, 0, take)
      rest = binary_part(buffer, take, byte_size(buffer) - take)
      remaining = remaining - take
      body = %{body | buffer: rest, remaining: remaining}

      if remaining == 0,
        do: parse_chunked(%{body | phase: :data_crlf}, [emit | emits]),
        else: {:ok, Enum.reverse([emit | emits]), body}
    end
  end

  defp chunk_data_crlf(%__MODULE__{buffer: buffer} = body, emits) do
    case buffer do
      <<"\r\n", rest::binary>> ->
        parse_chunked(%{body | buffer: rest, phase: :size}, emits)

      partial when byte_size(partial) < 2 ->
        {:ok, Enum.reverse(emits), body}

      _other ->
        {:error, :invalid_chunk_terminator}
    end
  end

  defp chunk_trailers(%__MODULE__{buffer: buffer} = body, emits) do
    case :binary.match(buffer, "\r\n") do
      :nomatch -> trailer_more(body, emits)
      {position, 2} -> trailer_line(body, emits, position)
    end
  end

  defp trailer_more(%__MODULE__{buffer: buffer} = body, emits) do
    if byte_size(buffer) > @max_line_bytes,
      do: {:error, :trailer_too_long},
      else: {:ok, Enum.reverse(emits), body}
  end

  defp trailer_line(%__MODULE__{buffer: buffer} = body, emits, position) do
    rest = binary_part(buffer, position + 2, byte_size(buffer) - position - 2)

    if position == 0 do
      if rest == <<>> do
        {:done, Enum.reverse(emits), %{body | buffer: rest, phase: :size}}
      else
        {:error, :unexpected_bytes}
      end
    else
      trailer_section(body, emits, rest, position)
    end
  end

  defp trailer_section(body, emits, rest, position) do
    trailer_bytes = body.trailer_bytes + position + 2

    if trailer_bytes > body.trailer_max,
      do: {:error, :trailer_too_large},
      else: parse_chunked(%{body | buffer: rest, trailer_bytes: trailer_bytes}, emits)
  end

  defp parse_hex_size(line) do
    size =
      line
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()

    case Integer.parse(size, 16) do
      {value, ""} when value >= 0 -> {:ok, value}
      _other -> :error
    end
  end
end
