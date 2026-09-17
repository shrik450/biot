defmodule BiotWeb.Preview.WebSocket do
  @moduledoc """
  Pure RFC 6455 framing for the preview WebSocket tunnel.

  One direction is ours to frame and the other is ours to parse:

    * Browser to application: WebSock hands over whole messages, so `encode/3` writes one masked
      client frame. Masking is random and is the only effect in this module.
    * Application to browser: `decode/2` parses server frames, reassembles fragmented messages, and
      returns typed events. It never interprets a payload; it forwards the opcode and bytes.

  Every frame length is checked against `max` before the payload is taken, and a reassembled message
  is bounded by the same `max`, so a hostile application cannot make the relay allocate without
  limit. The parser returns `{:error, reason}` for every malformed input; it never raises.
  """

  @continuation 0x0
  @text 0x1
  @binary 0x2
  @close 0x8
  @ping 0x9
  @pong 0xA

  # The close codes an application may send. 1004, 1005, 1006, and 1015 are reserved and must not
  # appear on the wire; 3000..4999 are application/private use.
  @close_codes [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014]

  # A frame header is at most two bytes plus eight extended-length bytes plus four mask bytes.
  @header_bytes 14

  defstruct max: 1_000_000, buffer: <<>>, fragment: nil

  @type opcode :: :text | :binary
  @type event ::
          {:data, opcode(), binary()}
          | {:ping, binary()}
          | {:pong, binary()}
          | {:close, non_neg_integer() | nil, binary()}

  @type t :: %__MODULE__{
          max: pos_integer(),
          buffer: binary(),
          fragment: nil | %{opcode: opcode(), chunks: [binary()], size: non_neg_integer()}
        }

  # The configured bound on one frame and on one reassembled message.
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: Application.fetch_env!(:biot_server, :max_frame_bytes)

  @spec new(pos_integer()) :: t()
  def new(max) when is_integer(max) and max > 0, do: %__MODULE__{max: max}

  @doc "Encodes one masked client frame for a data or control opcode."
  @spec encode(t(), :text | :binary | :ping | :pong, binary()) ::
          {:ok, binary()} | {:error, :frame_too_large}
  def encode(%__MODULE__{max: max}, opcode, payload)
      when opcode in [:text, :binary, :ping, :pong] and is_binary(payload) do
    cond do
      # A control frame's payload is capped at 125 by the WebSocket protocol, independently of
      # the larger bound for data frames.
      opcode in [:ping, :pong] and byte_size(payload) > 125 -> {:error, :frame_too_large}
      byte_size(payload) > max -> {:error, :frame_too_large}
      true -> {:ok, frame(opcode, payload)}
    end
  end

  @doc "Parses as many complete frames as `data` completes, returning typed events."
  @spec decode(t(), binary()) :: {:ok, [event()], t()} | {:error, term()}
  def decode(%__MODULE__{} = state, data) when is_binary(data) do
    parse(%{state | buffer: state.buffer <> data}, [])
  end

  defp frame(opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    {length, extended} = length_fields(byte_size(payload))

    [
      <<1::1, 0::3, opcode_byte(opcode)::4, 1::1, length::7>>,
      extended,
      mask,
      masked(payload, mask)
    ]
    |> IO.iodata_to_binary()
  end

  defp length_fields(size) when size <= 125, do: {size, <<>>}
  defp length_fields(size) when size <= 65_535, do: {126, <<size::16>>}
  defp length_fields(size), do: {127, <<size::64>>}

  defp masked(payload, mask) do
    size = byte_size(payload)
    repeats = div(size, 4) + 1
    repeated = binary_part(:binary.copy(mask, repeats), 0, size)
    :crypto.exor(payload, repeated)
  end

  defp opcode_byte(:text), do: @text
  defp opcode_byte(:binary), do: @binary
  defp opcode_byte(:ping), do: @ping
  defp opcode_byte(:pong), do: @pong

  defp parse(%__MODULE__{buffer: <<>>} = state, events), do: {:ok, Enum.reverse(events), state}

  defp parse(%__MODULE__{buffer: buffer} = state, events) do
    case header(buffer) do
      :more -> more(state, events)
      {:error, reason} -> {:error, reason}
      {:ok, fin, opcode, length, rest} -> frame(state, events, fin, opcode, length, rest)
    end
  end

  defp more(%__MODULE__{buffer: buffer} = state, events) do
    if byte_size(buffer) > @header_bytes,
      do: {:error, :invalid_frame},
      else: {:ok, Enum.reverse(events), state}
  end

  defp frame(%__MODULE__{max: max} = state, events, fin, opcode, length, rest) do
    cond do
      length > max ->
        {:error, :frame_too_large}

      control?(opcode) and (fin != 1 or length > 125) ->
        {:error, :invalid_control_frame}

      not known_opcode?(opcode) ->
        {:error, :invalid_opcode}

      byte_size(rest) < length ->
        {:ok, Enum.reverse(events), state}

      true ->
        take(state, events, fin, opcode, length, rest)
    end
  end

  defp take(state, events, fin, opcode, length, rest) do
    <<payload::binary-size(^length), remaining::binary>> = rest
    consume(%{state | buffer: remaining}, events, fin, opcode, payload)
  end

  defp consume(state, events, _fin, @ping, payload), do: parse(state, [{:ping, payload} | events])
  defp consume(state, events, _fin, @pong, payload), do: parse(state, [{:pong, payload} | events])

  defp consume(_state, _events, _fin, @close, <<_single_byte>>),
    do: {:error, :invalid_close_payload}

  defp consume(state, events, _fin, @close, payload) do
    if valid_close?(payload) do
      {:ok, Enum.reverse([{:close, close_code(payload), close_reason(payload)} | events]), state}
    else
      {:error, :invalid_close_frame}
    end
  end

  defp consume(%__MODULE__{fragment: nil} = state, events, 1, opcode, payload)
       when opcode in [@text, @binary] do
    parse(state, [{:data, data_opcode(opcode), payload} | events])
  end

  defp consume(%__MODULE__{fragment: nil, max: max} = state, events, 0, opcode, payload)
       when opcode in [@text, @binary] do
    if byte_size(payload) > max do
      {:error, :message_too_large}
    else
      chunks = if payload == <<>>, do: [], else: [payload]
      fragment = %{opcode: data_opcode(opcode), chunks: chunks, size: byte_size(payload)}
      parse(%{state | fragment: fragment}, events)
    end
  end

  defp consume(%__MODULE__{fragment: nil}, _events, _fin, @continuation, _payload),
    do: {:error, :unexpected_continuation}

  defp consume(%__MODULE__{fragment: _fragment}, _events, _fin, opcode, _payload)
       when opcode in [@text, @binary],
       do: {:error, :unexpected_data_frame}

  defp consume(
         %__MODULE__{fragment: fragment, max: max} = state,
         events,
         fin,
         @continuation,
         payload
       ) do
    size = fragment.size + byte_size(payload)

    if size > max do
      {:error, :message_too_large}
    else
      # An empty continuation adds no bytes, so retaining it would let an application grow the
      # chunk list without ever tripping the byte bound.
      chunks = if payload == <<>>, do: fragment.chunks, else: [payload | fragment.chunks]
      fragment = %{fragment | chunks: chunks, size: size}

      if fin == 1 do
        data = fragment.chunks |> Enum.reverse() |> IO.iodata_to_binary()
        parse(%{state | fragment: nil}, [{:data, fragment.opcode, data} | events])
      else
        parse(%{state | fragment: fragment}, events)
      end
    end
  end

  # Returns {:ok, fin, opcode, length, rest} or :more, or an error for a broken header.
  defp header(<<fin::1, rsv::3, opcode::4, masked::1, length::7, rest::binary>>) do
    cond do
      rsv != 0 -> {:error, :invalid_rsv}
      masked != 0 -> {:error, :masked_server_frame}
      length == 126 -> extended_16(rest, fin, opcode)
      length == 127 -> extended_64(rest, fin, opcode)
      true -> {:ok, fin, opcode, length, rest}
    end
  end

  defp header(_partial), do: :more

  defp extended_16(<<length::16, rest::binary>>, fin, opcode),
    do: {:ok, fin, opcode, length, rest}

  defp extended_16(_partial, _fin, _opcode), do: :more

  defp extended_64(<<length::64, rest::binary>>, fin, opcode) when length < 0x8000000000000000,
    do: {:ok, fin, opcode, length, rest}

  defp extended_64(<<_length::64, _rest::binary>>, _fin, _opcode), do: {:error, :invalid_frame}
  defp extended_64(_partial, _fin, _opcode), do: :more

  defp control?(opcode), do: opcode in [@close, @ping, @pong]
  defp known_opcode?(opcode), do: opcode in [@continuation, @text, @binary, @close, @ping, @pong]
  defp data_opcode(@text), do: :text
  defp data_opcode(@binary), do: :binary

  defp close_code(<<code::16, _reason::binary>>), do: code
  defp close_code(_payload), do: nil

  defp valid_close?(<<>>), do: true

  defp valid_close?(<<code::16, reason::binary>>) do
    (code in @close_codes or code in 3000..4999) and String.valid?(reason)
  end

  defp close_reason(<<_code::16, reason::binary>>), do: reason
  defp close_reason(_payload), do: <<>>
end
