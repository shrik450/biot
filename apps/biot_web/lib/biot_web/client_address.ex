defmodule BiotWeb.ClientAddress do
  @moduledoc """
  Decides a request's client address. Only a trusted edge peer may supply one, and only through
  `X-Forwarded-For`. The control scheme and host come from configuration, never from headers.

  The edge replaces any client-supplied forwarding headers with its own, so the last
  `X-Forwarded-For` entry is the one the edge wrote. Earlier entries come from the client and are
  never used.

  Every address is kept in canonical form: an IPv4-mapped IPv6 address becomes its IPv4 address.
  A listener on `::` sees an IPv4 edge as `::ffff:a.b.c.d`, while the operator lists it as
  `a.b.c.d`.
  """

  @typedoc "Canonical addresses of the trusted edge peers, as `parse_peers/1` returns them."
  @type peers :: [:inet.ip_address()]

  @doc """
  Parses the comma-separated `BIOT_TRUSTED_EDGE_PEERS` value. A blank value trusts no peer. CIDR
  ranges are out of scope, so each entry is one IPv4 or IPv6 address.
  """
  @spec parse_peers(String.t()) :: {:ok, peers()} | {:error, {:invalid_peer, String.t()}}
  def parse_peers(value) do
    case String.trim(value) do
      "" -> {:ok, []}
      _listed -> value |> String.split(",") |> Enum.map(&String.trim/1) |> parse_peers([])
    end
  end

  defp parse_peers([], peers), do: {:ok, Enum.reverse(peers)}

  defp parse_peers([entry | entries], peers) do
    case parse_address(entry) do
      {:ok, peer} -> parse_peers(entries, [peer | peers])
      :error -> {:error, {:invalid_peer, entry}}
    end
  end

  @doc """
  Returns the client address for a request from `peer_ip`. A trusted peer's last
  `X-Forwarded-For` entry wins when it parses. Otherwise the peer's own address stands.
  """
  @spec resolve(:inet.ip_address(), peers(), [String.t()]) :: :inet.ip_address()
  def resolve(peer_ip, trusted, x_forwarded_for_values) do
    peer = canonical(peer_ip)

    with true <- peer in trusted,
         {:ok, client} <- edge_entry(x_forwarded_for_values) do
      client
    else
      _untrusted_or_unparsed -> peer
    end
  end

  defp edge_entry(x_forwarded_for_values) do
    x_forwarded_for_values
    |> Enum.flat_map(&String.split(&1, ","))
    |> List.last("")
    |> String.trim()
    |> parse_address()
  end

  # A header value need not be UTF-8, and `String.to_charlist/1` raises on bytes that are not.
  defp parse_address(text) do
    case :inet.parse_strict_address(:binary.bin_to_list(text)) do
      {:ok, address} -> {:ok, canonical(address)}
      {:error, :einval} -> :error
    end
  end

  defp canonical({0, 0, 0, 0, 0, 0xFFFF, _high, _low} = mapped),
    do: :inet.ipv4_mapped_ipv6_address(mapped)

  defp canonical(address), do: address
end
