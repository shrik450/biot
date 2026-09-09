defmodule Biot.Protocol.Platform do
  @moduledoc "A supported Nix host system reported by a node."

  @platforms [:x86_64_linux, :aarch64_linux]
  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: :x86_64_linux | :aarch64_linux}

  @spec parse(term()) :: {:ok, t()} | {:error, :unsupported_platform | :invalid_format}
  def parse("x86_64-linux"), do: {:ok, %__MODULE__{value: :x86_64_linux}}
  def parse("aarch64-linux"), do: {:ok, %__MODULE__{value: :aarch64_linux}}
  def parse(value) when is_binary(value), do: {:error, :unsupported_platform}
  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: :x86_64_linux}), do: "x86_64-linux"
  def to_string(%__MODULE__{value: :aarch64_linux}), do: "aarch64-linux"

  @spec values() :: [atom()]
  def values, do: @platforms

  @spec current() :: {:ok, t()} | {:error, :unsupported_platform}
  def current do
    :erlang.system_info(:system_architecture)
    |> List.to_string()
    |> parse_architecture()
  end

  defp parse_architecture("x86_64-" <> target), do: parse_linux_target(target, "x86_64-linux")
  defp parse_architecture("aarch64-" <> target), do: parse_linux_target(target, "aarch64-linux")
  defp parse_architecture("arm64-" <> target), do: parse_linux_target(target, "aarch64-linux")
  defp parse_architecture(_architecture), do: {:error, :unsupported_platform}

  defp parse_linux_target(target, platform) do
    case String.split(target, "-") do
      ["linux" | _rest] -> parse(platform)
      [_vendor, "linux" | _rest] -> parse(platform)
      _other -> {:error, :unsupported_platform}
    end
  end
end

defimpl String.Chars, for: Biot.Protocol.Platform do
  def to_string(value), do: Biot.Protocol.Platform.to_string(value)
end
