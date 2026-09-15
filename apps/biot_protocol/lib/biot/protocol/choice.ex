defmodule Biot.Protocol.Choice do
  @moduledoc "One of a closed set of atoms, written on the wire as its name."

  @spec parse(term(), [atom()]) :: {:ok, atom()} | {:error, :invalid_format}
  def parse(value, choices) when is_binary(value) do
    case Enum.find(choices, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_format}
      choice -> {:ok, choice}
    end
  end

  def parse(_value, _choices), do: {:error, :invalid_format}
end
