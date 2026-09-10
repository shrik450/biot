defmodule Biot.Node.Journal.Ecto.Attempts do
  @moduledoc """
  Stores retry attempt counts, keyed by lifecycle stage, as one JSON object.

  Every entry is one lifecycle stage and the number of attempts it has spent, so the counts a
  controller reads back are the counts its retry arithmetic can use.
  """

  use Ecto.Type

  alias Biot.Protocol.Failure

  @impl true
  def type, do: :map

  @impl true
  def cast(value), do: attempts(value)

  @impl true
  def load(value) do
    case attempts(value) do
      {:ok, attempts} -> {:ok, attempts}
      :error -> raise ArgumentError, "stored attempts are corrupt: #{inspect(value)}"
    end
  end

  @impl true
  def dump(value) do
    case attempts(value) do
      {:ok, attempts} ->
        {:ok, Map.new(attempts, fn {stage, count} -> {Atom.to_string(stage), count} end)}

      :error ->
        :error
    end
  end

  defp attempts(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn entry, {:ok, attempts} ->
      case attempt(entry) do
        {:ok, stage, count} -> {:cont, {:ok, Map.put(attempts, stage, count)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp attempts(_value), do: :error

  defp attempt({stage, count}) when is_integer(count) and count > 0 do
    case stage(stage) do
      {:ok, stage} -> {:ok, stage, count}
      {:error, _reason} -> :error
    end
  end

  defp attempt(_entry), do: :error

  # A stored key arrives as the encoded name and a cast key as the stage itself, and `Failure` owns
  # the one set both belong to.
  defp stage(value) when is_atom(value), do: Failure.parse_stage(Atom.to_string(value))
  defp stage(value), do: Failure.parse_stage(value)
end
