defmodule Biot.Node.StorePath do
  @moduledoc """
  A parsed path at or inside one object in the Nix store.

  Biot nodes use `/nix/store` as the fixed store root.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  @store_root "/nix/store"
  @store_object ~r/\A[0-9abcdfghijklmnpqrsvwxyz]{32}-[0-9A-Za-z+._?=-]+\z/

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    relative = Path.relative_to(value, @store_root)

    case Path.split(relative) do
      [store_object | rest] when relative != value ->
        parse_segments(value, store_object, rest)

      _other ->
        {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value

  @doc """
  The store object's own name, without the hash that precedes it.

  Nix derives a fixed-output path from a NAR hash and this name, so a copy of the same bytes kept
  under this name is the same store path.
  """
  @spec object_name(t()) :: String.t()
  def object_name(%__MODULE__{value: value}) do
    [object | _rest] = value |> Path.relative_to(@store_root) |> Path.split()
    String.slice(object, 33..-1//1)
  end

  defp parse_segments(value, store_object, rest) do
    if Regex.match?(@store_object, store_object) and canonical?(value, store_object, rest) do
      {:ok, %__MODULE__{value: value}}
    else
      {:error, :invalid_format}
    end
  end

  # Only the canonical spelling parses, so one location cannot have two parsed forms.
  defp canonical?(value, store_object, rest) do
    Enum.all?(rest, &named?/1) and Path.join([@store_root, store_object | rest]) == value
  end

  defp named?(segment),
    do: segment not in ["", ".", ".."] and not String.contains?(segment, <<0>>)
end

defimpl String.Chars, for: Biot.Node.StorePath do
  def to_string(value), do: Biot.Node.StorePath.to_string(value)
end
