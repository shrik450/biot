defmodule Biot.Protocol.BiotName do
  @moduledoc """
  An owner's name for a Biot: a lowercase DNS label.

  Names appear in URLs, command lines, and logs, so they carry no spaces, slashes, or case to
  normalize. A name that is a canonical UUID is rejected, so a client can tell a name from a
  `BiotId` without asking the server.
  """

  alias Biot.Protocol.CanonicalUuid

  @name_pattern ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
  @max_length 63

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format | :name_too_long}
  def parse(value) when is_binary(value) do
    cond do
      not Regex.match?(@name_pattern, value) ->
        {:error, :invalid_format}

      match?({:ok, _uuid}, CanonicalUuid.parse(value)) ->
        {:error, :invalid_format}

      byte_size(value) > @max_length ->
        {:error, :name_too_long}

      true ->
        {:ok, %__MODULE__{value: value}}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @doc "The maximum number of bytes in a Biot name."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

defimpl String.Chars, for: Biot.Protocol.BiotName do
  def to_string(value), do: Biot.Protocol.BiotName.to_string(value)
end
