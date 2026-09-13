defmodule Biot.Protocol.SshPublicKey do
  @moduledoc """
  One OpenSSH public key line.

  The fingerprint is the SHA-256 fingerprint OpenSSH prints.
  """

  @enforce_keys [:line, :fingerprint]
  defstruct [:line, :fingerprint]

  @type t :: %__MODULE__{line: String.t(), fingerprint: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(line) when is_binary(line) do
    if String.contains?(line, "\n"), do: {:error, :invalid_format}, else: decode(line)
  end

  def parse(_line), do: {:error, :invalid_format}

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{fingerprint: fingerprint}), do: fingerprint

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{line: line}), do: line

  defp decode(line) do
    case String.split(line) do
      [algorithm, blob | _comment] -> decode_key(algorithm, blob)
      _none_or_missing_blob -> {:error, :invalid_format}
    end
  end

  # `:ssh_file.decode/2` rejects a comment that contains spaces, so the key
  # type and blob go in alone.
  defp decode_key(algorithm, blob) do
    case :ssh_file.decode(algorithm <> " " <> blob, :openssh_key) do
      [{key, _attrs}] ->
        canonical = :ssh_file.encode([{key, []}], :openssh_key) |> String.trim_trailing()
        wire_blob = :ssh_file.encode(key, :ssh2_pubkey)

        if String.starts_with?(canonical, algorithm <> " ") do
          {:ok, %__MODULE__{line: canonical, fingerprint: compute_fingerprint(wire_blob)}}
        else
          {:error, :invalid_format}
        end

      _none_or_many ->
        {:error, :invalid_format}
    end
  rescue
    ArgumentError -> {:error, :invalid_format}
  end

  defp compute_fingerprint(blob) do
    "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
  end
end

defimpl String.Chars, for: Biot.Protocol.SshPublicKey do
  def to_string(value), do: Biot.Protocol.SshPublicKey.to_string(value)
end
