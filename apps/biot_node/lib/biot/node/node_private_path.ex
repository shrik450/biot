defmodule Biot.Node.NodePrivatePath do
  @moduledoc """
  An absolute host path the node owns. Allocation metadata, initialization markers, and resolution
  snapshots live at these paths, outside any mount a biot can write.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    case canonical?(value, Path.split(value)) do
      true -> {:ok, %__MODULE__{value: value}}
      false -> {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value

  # Only the canonical spelling parses, so `to_string/1` round-trips and two records for the same
  # location cannot differ by a trailing or doubled separator.
  defp canonical?(value, ["/" | segments]) do
    segments != [] and Path.join(["/" | segments]) == value and Enum.all?(segments, &named?/1)
  end

  defp canonical?(_value, _segments), do: false

  defp named?(segment) do
    segment not in [".", ".."] and not String.contains?(segment, <<0>>)
  end
end

defimpl String.Chars, for: Biot.Node.NodePrivatePath do
  def to_string(value), do: Biot.Node.NodePrivatePath.to_string(value)
end
