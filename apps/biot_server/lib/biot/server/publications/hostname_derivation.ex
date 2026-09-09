defmodule Biot.Server.Publications.HostnameDerivation do
  @moduledoc "Derives stable publication hostnames from a Biot and port."

  alias Biot.Protocol.{BiotId, Hostname, Port}

  @version 1

  @spec derive(BiotId.t(), Port.t(), binary()) :: Hostname.t()
  def derive(%BiotId{} = biot_id, %Port{value: port}, key) when is_binary(key) do
    uuid = Ecto.UUID.dump!(BiotId.to_string(biot_id))
    input = <<@version, uuid::binary-size(16), port::unsigned-big-integer-size(16)>>
    digest = :crypto.mac(:hmac, :sha256, key, input)
    label = digest |> binary_part(0, 16) |> Base.encode32(case: :lower, padding: false)

    # Base32 for 16 bytes always meets the hostname value rules.
    {:ok, hostname} = Hostname.parse(label)
    hostname
  end
end
