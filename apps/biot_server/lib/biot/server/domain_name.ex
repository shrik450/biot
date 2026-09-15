defmodule Biot.Server.DomainName do
  @moduledoc """
  Lowercase DNS names for the control host and the publication domain.

  Every preview hostname is one label under the publication domain, so the control host must sit
  outside it: a control host inside the domain would be a name a preview could also answer to.
  """

  alias Biot.Protocol.Hostname

  @max_bytes 253

  @spec parse(term()) :: {:ok, String.t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) and byte_size(value) <= @max_bytes do
    if value |> String.split(".") |> Enum.all?(&label?/1),
      do: {:ok, value},
      else: {:error, :invalid_format}
  end

  def parse(_value), do: {:error, :invalid_format}

  @doc "Whether `name` is `domain` itself or a name under it."
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(name, domain), do: name == domain or String.ends_with?(name, "." <> domain)

  defp label?(label), do: match?({:ok, _hostname}, Hostname.parse(label))
end
