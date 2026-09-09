defmodule Biot.Server.Ecto.ProtocolValue do
  @moduledoc """
  Stores one parsed protocol value in its canonical string form. Every value,
  including Port, is text, so SQL ordering is lexicographic and only equality is meaningful.
  """

  use Ecto.ParameterizedType

  @impl true
  def init(opts) do
    module = Keyword.fetch!(opts, :module)
    Code.ensure_loaded!(module)

    unless function_exported?(module, :parse, 1) and function_exported?(module, :to_string, 1) do
      raise ArgumentError, "#{inspect(module)} is not a parsed protocol value"
    end

    %{module: module}
  end

  @impl true
  def type(_params), do: :string

  @impl true
  def cast(nil, _params), do: {:ok, nil}

  def cast(value, %{module: module}) do
    if is_struct(value, module) do
      {:ok, value}
    else
      case module.parse(value) do
        {:ok, parsed} -> {:ok, parsed}
        {:error, _reason} -> :error
      end
    end
  end

  @impl true
  def load(nil, _loader, _params), do: {:ok, nil}

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
  def dump(nil, _dumper, _params), do: {:ok, nil}

  def dump(value, _dumper, %{module: module}) do
    if is_struct(value, module) do
      {:ok, module.to_string(value)}
    else
      :error
    end
  end
end
