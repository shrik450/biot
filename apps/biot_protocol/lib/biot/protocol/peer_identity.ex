defmodule Biot.Protocol.PeerIdentity do
  @moduledoc "Computes the lowercase SHA-256 fingerprint of certificate SubjectPublicKeyInfo DER."

  @spec from_certificate(binary()) :: {:ok, String.t()} | {:error, :invalid_certificate}
  def from_certificate(der) when is_binary(der) do
    fingerprint =
      der
      |> X509.Certificate.from_der!()
      |> X509.Certificate.public_key()
      |> X509.PublicKey.to_der()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, fingerprint}
  rescue
    _error -> {:error, :invalid_certificate}
  end
end
