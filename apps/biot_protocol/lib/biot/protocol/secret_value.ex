defmodule Biot.Protocol.SecretValue do
  @moduledoc """
  One delivered runtime secret value: the bytes an environment variable can hold.

  That is the whole definition, and it is the reason for the one rule beyond the size bound. A
  value becomes an environment variable for the biot's services and shells, and a process
  environment cannot represent a NUL byte, so a value containing one is refused here rather than
  delivered faithfully to a file and then silently truncated on its way into a shell. Everything
  else survives: empty values, embedded and trailing newlines, and bytes that are not valid UTF-8.
  The launcher reads each file with a sentinel so a trailing newline is not eaten by the shell.

  The value exists as a bare binary in `parse/2` and in whatever writes the file, and nowhere else.
  Everything between holds this struct, whose `Inspect` implementation prints nothing, so a log
  line, a codec error, and an OTP crash report all filter it without knowing that they did.
  """

  alias Biot.Protocol.Limits

  @derive {Inspect, only: []}
  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: binary()}

  @spec parse(term(), pos_integer()) ::
          {:ok, t()} | {:error, :invalid_format | :secret_value_too_large | :nul_byte}
  def parse(value, version) when is_binary(value) do
    cond do
      byte_size(value) > Limits.max_secret_value_bytes(version) ->
        {:error, :secret_value_too_large}

      String.contains?(value, <<0>>) ->
        {:error, :nul_byte}

      true ->
        {:ok, %__MODULE__{value: value}}
    end
  end

  def parse(_value, _version), do: {:error, :invalid_format}

  @doc "The bytes to write. Every caller of this is a boundary that has to hold the value."
  @spec reveal(t()) :: binary()
  def reveal(%__MODULE__{value: value}), do: value
end
