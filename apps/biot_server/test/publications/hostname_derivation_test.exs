defmodule Biot.Server.Publications.HostnameDerivationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.{BiotId, Port}
  alias Biot.Server.Publications.HostnameDerivation

  test "derive matches independently computed fixed vectors" do
    vectors = [
      {"test-key", "00000000-0000-4000-8000-000000002001", 4_000, "3dqbs6pwnuvcjxls7tt7ss4va4"},
      {<<0, 1, 2, 3, 255>>, "ffffffff-ffff-4fff-bfff-ffffffffffff", 65_535,
       "clvjuksxi4kysvslhbxdl5qixa"}
    ]

    for {key, uuid, port_value, expected} <- vectors do
      biot_id = parse_id(uuid)
      port = parse_port(port_value)

      assert reference_label(key, uuid, port_value, 1) == expected
      assert HostnameDerivation.derive(biot_id, port, key) |> to_string() == expected
    end
  end

  property "the label is stable, valid, and sensitive to every derivation input" do
    check all(
            key <- StreamData.binary(min_length: 1, max_length: 64),
            suffix <- StreamData.integer(1..999_999_999_998),
            port_value <- StreamData.integer(1..65_534)
          ) do
      uuid = uuid(suffix)
      other_uuid = uuid(suffix + 1)
      biot_id = parse_id(uuid)
      other_biot_id = parse_id(other_uuid)
      port = parse_port(port_value)
      other_port = parse_port(port_value + 1)

      label = HostnameDerivation.derive(biot_id, port, key) |> to_string()
      <<first, rest::binary>> = key
      other_key = <<Bitwise.bxor(first, 1), rest::binary>>

      assert label == HostnameDerivation.derive(biot_id, port, key) |> to_string()
      assert label =~ ~r/\A[a-z2-7]{26}\z/
      assert label == reference_label(key, uuid, port_value, 1)
      refute label == HostnameDerivation.derive(biot_id, port, other_key) |> to_string()
      refute label == HostnameDerivation.derive(other_biot_id, port, key) |> to_string()
      refute label == HostnameDerivation.derive(biot_id, other_port, key) |> to_string()
      refute label == reference_label(key, uuid, port_value, 2)
    end
  end

  defp reference_label(key, uuid, port, version) do
    uuid_bytes = uuid |> String.replace("-", "") |> Base.decode16!(case: :mixed)
    input = <<version, uuid_bytes::binary-size(16), port::unsigned-big-integer-size(16)>>

    key
    |> then(&:crypto.mac(:hmac, :sha256, &1, input))
    |> binary_part(0, 16)
    |> Base.encode32(case: :lower, padding: false)
  end

  defp uuid(suffix) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(suffix), 12, "0")
  end

  defp parse_id(value) do
    {:ok, biot_id} = BiotId.parse(value)
    biot_id
  end

  defp parse_port(value) do
    {:ok, port} = Port.parse(value)
    port
  end
end
