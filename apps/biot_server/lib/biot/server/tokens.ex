defmodule Biot.Server.Tokens do
  @moduledoc """
  Mints bearer tokens and hashes presented tokens for storage lookup.

  Minting is an effect. A caller stores the returned digest and gives the clear
  token to exactly one client.
  """

  alias Biot.Protocol.Digest

  @token_bytes 32

  @spec mint(String.t()) :: {String.t(), Digest.t()}
  def mint(prefix \\ "") do
    token = prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
    {token, digest(token)}
  end

  @spec digest(String.t()) :: Digest.t()
  def digest(token) when is_binary(token), do: Digest.sha256(token)
end
