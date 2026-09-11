defmodule Biot.Protocol.NarHash do
  @moduledoc """
  The one definition of Nix's NAR hash form: `sha256-` followed by the padded base64 of 32 bytes.

  A pinned source and one environment's staged inputs both carry these, and both are only as
  trustworthy as the check on them, so the check lives in one place. The canonical text is the
  value: it is what Nix is given back and what a manifest encodes.
  """

  @type t :: String.t()

  @prefix "sha256-"
  @digest_bytes 32

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    with @prefix <> encoded <- value,
         {:ok, digest} <- Base.decode64(encoded),
         true <- byte_size(digest) == @digest_bytes,
         # Only the canonical spelling parses, so one hash cannot have two forms.
         ^value <- @prefix <> Base.encode64(digest) do
      {:ok, value}
    else
      _other -> {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}
end
