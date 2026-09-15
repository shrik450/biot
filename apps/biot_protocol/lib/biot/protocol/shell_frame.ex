defmodule Biot.Protocol.ShellFrame do
  @moduledoc """
  The shell frame codec the server and the node share. The Go agent speaks the same wire
  contract in its own code.

  A direction decides which frame types are legal: data flows both ways, resize only toward the
  agent, and exit only toward the server. The node validates untrusted agent frames with this
  codec, and the server uses the same contract, so a replaced agent cannot force unbounded
  buffering or smuggle a type the peer never sends.
  """

  @data 0
  @resize 1
  @exit 2
  # `FramePayloadLimit` in `agent/protocol/frame.go` repeats this, so both sides refuse the same
  # frames.
  @max_payload 65_536

  @type direction :: :to_agent | :to_server
  @type frame :: {:data, binary()} | {:resize, 1..65_535, 1..65_535} | {:exit, 0..255}
  @type error_reason :: :frame_too_large | :invalid_frame

  @spec max_payload() :: pos_integer()
  def max_payload, do: @max_payload

  @spec encode(frame()) :: {:ok, iodata()} | {:error, error_reason()}
  def encode({:data, payload})
      when is_binary(payload) and byte_size(payload) <= @max_payload do
    {:ok, frame(@data, payload)}
  end

  def encode({:data, payload}) when is_binary(payload), do: {:error, :frame_too_large}

  def encode({:resize, cols, rows})
      when is_integer(cols) and is_integer(rows) and cols in 1..65_535 and rows in 1..65_535 do
    {:ok, frame(@resize, <<cols::16, rows::16>>)}
  end

  def encode({:exit, status}) when is_integer(status) and status in 0..255 do
    {:ok, frame(@exit, <<status>>)}
  end

  def encode(_frame), do: {:error, :invalid_frame}

  @spec decode(binary(), direction()) ::
          {:ok, [frame()], binary()} | {:error, error_reason()}
  def decode(buffer, direction)
      when is_binary(buffer) and direction in [:to_agent, :to_server] do
    decode_frames(buffer, direction, @max_payload, [])
  end

  @doc """
  Decodes, re-encodes, and stops after an exit frame.

  This is the one re-framing rule: a relay passes the bytes it read, gets back the bytes to send
  and any partial frame to keep, or is told the stream ended with an exit. Direction decides which
  frame types are legal.
  """
  @spec reframe(binary(), direction()) ::
          {:ok, iodata(), binary()} | {:exit, iodata()} | {:error, error_reason()}
  def reframe(buffer, direction) do
    case decode(buffer, direction) do
      {:ok, frames, rest} -> frame_result(frames, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp frame_result(frames, rest) do
    case Enum.split_while(frames, fn frame -> not match?({:exit, _status}, frame) end) do
      {before, [{:exit, _status} = exit | after_frames]} ->
        if after_frames == [] and rest == <<>> do
          {:exit, encode_frames(before ++ [exit])}
        else
          {:error, :invalid_frame}
        end

      {_before, []} ->
        {:ok, encode_frames(frames), rest}
    end
  end

  defp encode_frames(frames) do
    Enum.map(frames, fn frame ->
      {:ok, bytes} = encode(frame)
      bytes
    end)
  end

  defp decode_frames(buffer, _direction, _max_payload, frames) when byte_size(buffer) < 5 do
    {:ok, Enum.reverse(frames), buffer}
  end

  defp decode_frames(
         <<_type, length::unsigned-big-32, _rest::binary>>,
         _direction,
         max_payload,
         _frames
       )
       when length > max_payload do
    {:error, :frame_too_large}
  end

  defp decode_frames(
         <<type, length::unsigned-big-32, rest::binary>> = buffer,
         direction,
         max_payload,
         frames
       ) do
    if byte_size(rest) < length do
      {:ok, Enum.reverse(frames), buffer}
    else
      payload = binary_part(rest, 0, length)
      remainder = binary_part(rest, length, byte_size(rest) - length)

      case parse_frame(type, payload, direction) do
        {:ok, frame} -> decode_frames(remainder, direction, max_payload, [frame | frames])
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_frame(@data, payload, _direction), do: {:ok, {:data, payload}}

  defp parse_frame(@resize, <<cols::16, rows::16>>, :to_agent) when cols > 0 and rows > 0 do
    {:ok, {:resize, cols, rows}}
  end

  defp parse_frame(@exit, <<status>>, :to_server), do: {:ok, {:exit, status}}
  defp parse_frame(_type, _payload, _direction), do: {:error, :invalid_frame}

  defp frame(type, payload) do
    [<<type, byte_size(payload)::unsigned-big-32>>, payload]
  end
end
