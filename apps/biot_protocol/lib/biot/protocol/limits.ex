defmodule Biot.Protocol.Limits do
  @moduledoc "Owns the size limits for each protocol version."

  # 256 KiB. The largest spec the component limits allow encodes well under this.
  @max_biot_spec_bytes_v1 262_144
  @max_repository_url_bytes 2_048
  @max_source_ref_bytes 256
  @max_relative_directory_bytes 1_024
  @max_layers 16

  @spec max_biot_spec_bytes(pos_integer()) :: pos_integer()
  def max_biot_spec_bytes(1), do: @max_biot_spec_bytes_v1

  @spec max_repository_url_bytes() :: pos_integer()
  def max_repository_url_bytes, do: @max_repository_url_bytes

  @spec max_source_ref_bytes() :: pos_integer()
  def max_source_ref_bytes, do: @max_source_ref_bytes

  @spec max_relative_directory_bytes() :: pos_integer()
  def max_relative_directory_bytes, do: @max_relative_directory_bytes

  @spec max_layers() :: pos_integer()
  def max_layers, do: @max_layers
end
