defmodule Biot.Server.Label do
  @moduledoc "Validates the human label shared by credentials and SSH keys."

  @max_bytes 100

  @spec validate(term()) :: :ok | {:error, {:invalid_input, %{label: [:invalid_format]}}}
  def validate(label) when is_binary(label) do
    if byte_size(label) in 1..@max_bytes,
      do: :ok,
      else: {:error, {:invalid_input, %{label: [:invalid_format]}}}
  end

  def validate(_label), do: {:error, {:invalid_input, %{label: [:invalid_format]}}}
end
