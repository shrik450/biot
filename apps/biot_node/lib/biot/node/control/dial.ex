defmodule Biot.Node.Control.Dial do
  @moduledoc """
  Dials the server with mutual TLS and verifies its certificate.

  The control connection and every stream attach use this one function, so a change to server
  authentication happens in one place.
  """

  alias Biot.Protocol.PeerIdentity

  @type dial_options :: %{
          required(:server_host) => String.t(),
          required(:server_port) => pos_integer(),
          required(:server_fingerprint) => String.t(),
          required(:tls) => keyword()
        }

  @spec connect(dial_options(), pos_integer()) :: {:ok, :ssl.sslsocket()} | {:error, term()}
  def connect(dial, timeout_ms) do
    with {:ok, socket} <-
           :ssl.connect(
             String.to_charlist(dial.server_host),
             dial.server_port,
             tls_options(dial.tls),
             timeout_ms
           ),
         :ok <- verify_server(socket, dial.server_fingerprint) do
      {:ok, socket}
    end
  end

  defp tls_options(tls) do
    Keyword.merge(tls,
      verify: :verify_peer,
      active: false,
      mode: :binary,
      packet: :raw,
      server_name_indication: :disable
    )
  end

  defp verify_server(socket, fingerprint) do
    with {:ok, certificate} <- :ssl.peercert(socket),
         {:ok, peer} <- PeerIdentity.from_certificate(certificate),
         true <- fingerprints_match?(peer, fingerprint) do
      :ok
    else
      _error -> close(socket)
    end
  end

  defp close(socket) do
    _ = :ssl.close(socket)
    {:error, :server_fingerprint_mismatch}
  end

  defp fingerprints_match?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp fingerprints_match?(_left, _right), do: false
end
