defmodule BiotWeb.Preview.Limits do
  @moduledoc """
  The operator bounds for the preview proxy.

  They sit with the other server limits so a deployment sets them in one place. `max_frame_bytes`
  still bounds WebSocket frames and reassembly; these bound the HTTP side and the upstream
  handshake.
  """

  @spec request_max_bytes() :: pos_integer()
  def request_max_bytes, do: fetch(:preview_request_max_bytes)

  @spec request_chunk_bytes() :: pos_integer()
  def request_chunk_bytes, do: fetch(:preview_request_chunk_bytes)

  @spec head_max_bytes() :: pos_integer()
  def head_max_bytes, do: fetch(:preview_head_max_bytes)

  @spec exchange_timeout_ms() :: pos_integer()
  def exchange_timeout_ms, do: fetch(:preview_exchange_timeout_ms)

  @spec handshake_timeout_ms() :: pos_integer()
  def handshake_timeout_ms, do: fetch(:preview_handshake_timeout_ms)

  defp fetch(key), do: Application.fetch_env!(:biot_server, key)
end
