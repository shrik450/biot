defmodule Biot.Protocol.Frame do
  @moduledoc "Encodes and incrementally decodes length-prefixed control frames."

  @spec encode(iodata()) :: iodata()
  def encode(data) do
    size = IO.iodata_length(data)
    [<<size::unsigned-big-32>>, data]
  end

  @spec overhead_bytes() :: pos_integer()
  def overhead_bytes, do: encode([]) |> IO.iodata_length()

  @spec decode(binary(), pos_integer()) ::
          {:ok, [binary()], binary()} | {:error, {:frame_too_large, non_neg_integer()}}
  def decode(buffer, max_frame_bytes) when is_binary(buffer) and max_frame_bytes > 0 do
    decode_frames(buffer, max_frame_bytes, [])
  end

  @doc "Takes exactly one frame, leaving every byte after it untouched."
  @spec take(binary(), pos_integer()) ::
          {:ok, binary(), binary()} | :more | {:error, :frame_too_large}
  def take(<<size::unsigned-big-32, rest::binary>>, max_frame_bytes)
      when size <= max_frame_bytes do
    if byte_size(rest) >= size do
      {:ok, binary_part(rest, 0, size), binary_part(rest, size, byte_size(rest) - size)}
    else
      :more
    end
  end

  def take(<<_size::unsigned-big-32, _rest::binary>>, _max_frame_bytes),
    do: {:error, :frame_too_large}

  def take(_buffer, _max_frame_bytes), do: :more

  defp decode_frames(buffer, _max_frame_bytes, frames) when byte_size(buffer) < 4 do
    {:ok, Enum.reverse(frames), buffer}
  end

  defp decode_frames(<<size::unsigned-big-32, _rest::binary>>, max_frame_bytes, _frames)
       when size > max_frame_bytes do
    {:error, {:frame_too_large, size}}
  end

  defp decode_frames(<<size::unsigned-big-32, rest::binary>> = buffer, max_frame_bytes, frames) do
    if byte_size(rest) < size do
      {:ok, Enum.reverse(frames), buffer}
    else
      <<frame::binary-size(^size), remainder::binary>> = rest
      decode_frames(remainder, max_frame_bytes, [frame | frames])
    end
  end
end
