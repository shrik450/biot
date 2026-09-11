defmodule Biot.Protocol.SecretName do
  @moduledoc """
  The name one runtime secret is delivered under, which is also the environment variable a service
  and a shell see it as.

  The reserved names are the four `nix/module.nix` reserves for the launcher and the agent. They
  are named here as well because a name has to be refused at the boundary that accepts it, long
  before a bundle is evaluated; `nix/module.nix` carries the matching comment.
  """

  @reserved ~w(BIOT_CONFIG_ROOT HOME PATH TERM)

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @spec reserved() :: [String.t()]
  def reserved, do: @reserved

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format | :reserved_name}
  def parse(value) when is_binary(value) do
    cond do
      not Regex.match?(~r/\A[A-Z][A-Z0-9_]*\z/, value) -> {:error, :invalid_format}
      value in @reserved -> {:error, :reserved_name}
      true -> {:ok, %__MODULE__{value: value}}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

defimpl String.Chars, for: Biot.Protocol.SecretName do
  def to_string(value), do: Biot.Protocol.SecretName.to_string(value)
end
