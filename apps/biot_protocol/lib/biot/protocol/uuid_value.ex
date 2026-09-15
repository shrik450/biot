defmodule Biot.Protocol.UuidValue do
  @moduledoc """
  Defines an opaque identity whose one form is a canonical UUIDv4.

  `use Biot.Protocol.UuidValue` gives the module its struct, `parse/1`, `to_string/1`,
  `generate/0`, and `String.Chars`, so every ID parses and prints the same way.
  """

  defmacro __using__(_options) do
    quote do
      alias Biot.Protocol.CanonicalUuid

      @enforce_keys [:value]
      defstruct [:value]

      @opaque t :: %__MODULE__{value: String.t()}

      @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
      def parse(value) do
        with {:ok, value} <- CanonicalUuid.parse(value), do: {:ok, %__MODULE__{value: value}}
      end

      @spec to_string(t()) :: String.t()
      def to_string(%__MODULE__{value: value}), do: value

      @spec generate() :: t()
      def generate, do: %__MODULE__{value: CanonicalUuid.generate()}

      defimpl String.Chars do
        def to_string(value), do: @for.to_string(value)
      end
    end
  end
end
