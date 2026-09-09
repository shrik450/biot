defmodule Biot.Node.Journal.Ecto.ParsedValue do
  @moduledoc "Stores a parsed protocol or node value in its canonical string form."

  use Ecto.ParameterizedType

  @impl true
  def init(options) do
    %{module: Keyword.fetch!(options, :module)}
  end

  @impl true
  def type(_parameters), do: :string

  @impl true
  def cast(nil, _parameters), do: {:ok, nil}

  def cast(value, %{module: module}) do
    if is_struct(value, module), do: {:ok, value}, else: parse(module, value)
  end

  @impl true
  def load(nil, _loader, _parameters), do: {:ok, nil}

  def load(value, _loader, %{module: module}) when is_binary(value) do
    case module.parse(value) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        raise ArgumentError,
              "stored #{inspect(module)} value is corrupt: #{inspect(value)} (#{inspect(reason)})"
    end
  end

  def load(value, _loader, %{module: module}) do
    raise ArgumentError,
          "stored #{inspect(module)} value is corrupt: expected a string, got #{inspect(value)}"
  end

  @impl true
  def dump(nil, _dumper, _parameters), do: {:ok, nil}

  def dump(value, _dumper, %{module: module}) do
    if is_struct(value, module), do: {:ok, module.to_string(value)}, else: :error
  end

  defp parse(module, value) do
    case module.parse(value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end
end
