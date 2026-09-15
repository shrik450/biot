defmodule Biot.Protocol.Limits do
  @moduledoc "Owns the size limits for each protocol version."

  # 256 KiB. The largest spec the component limits allow encodes well under this.
  @max_biot_spec_bytes_v1 262_144
  # 64 KiB. A bound both peers agree on, rather than an operator setting, because
  # `Biot.Protocol.Wire.check_frame_limit!/1` has to account for it at boot in both releases and a
  # setting could be raised above the frame limit the link accepts.
  @max_secret_value_bytes_v1 65_536
  @max_repository_url_bytes 2_048
  @max_source_ref_bytes 256
  @max_layers 16
  # 16 KiB including the trailing newline: the agent reads its request line through this bound,
  # which `LineLimit` in `agent/protocol/request.go` repeats.
  @max_agent_line_bytes 16 * 1024

  @spec max_biot_spec_bytes(pos_integer()) :: pos_integer()
  def max_biot_spec_bytes(1), do: @max_biot_spec_bytes_v1

  @spec max_secret_value_bytes(pos_integer()) :: pos_integer()
  def max_secret_value_bytes(1), do: @max_secret_value_bytes_v1

  @spec max_repository_url_bytes() :: pos_integer()
  def max_repository_url_bytes, do: @max_repository_url_bytes

  @spec max_source_ref_bytes() :: pos_integer()
  def max_source_ref_bytes, do: @max_source_ref_bytes

  @spec max_layers() :: pos_integer()
  def max_layers, do: @max_layers

  @spec max_agent_line_bytes() :: pos_integer()
  def max_agent_line_bytes, do: @max_agent_line_bytes
end
