defmodule Biot.Server.DomainName do
  @moduledoc """
  Lowercase DNS names for the control host and the publication domain.

  Every preview hostname is one label under the publication domain, so the control host must sit
  outside it: a control host inside the domain would be a name a preview could also answer to.
  """

  alias Biot.Protocol.Hostname

  @max_bytes 253

  @typedoc "The three outcomes of dispatching one request by its `Host`."
  @type host_class :: :control | {:preview, Hostname.t()} | :unknown

  @spec parse(term()) :: {:ok, String.t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) and byte_size(value) <= @max_bytes do
    if value |> String.split(".") |> Enum.all?(&label?/1),
      do: {:ok, value},
      else: {:error, :invalid_format}
  end

  def parse(_value), do: {:error, :invalid_format}

  @doc """
  Classifies a request `Host` against the control host and the publication domain.

  The control host must sit outside the publication domain, so the two cases never overlap.
  A preview host is exactly one label under the domain; the domain apex and any deeper name
  are unknown, and the endpoint answers them with its not-found page.
  """
  @spec classify(String.t(), String.t(), String.t()) :: host_class()
  def classify(host, control_host, publication_domain) when is_binary(host) do
    if host == control_host, do: :control, else: preview(host, publication_domain)
  end

  defp preview(host, publication_domain) do
    suffix = "." <> publication_domain

    with true <- String.ends_with?(host, suffix),
         label = binary_part(host, 0, byte_size(host) - byte_size(suffix)),
         {:ok, hostname} <- Hostname.parse(label) do
      {:preview, hostname}
    else
      _not_a_preview -> :unknown
    end
  end

  @doc "Whether `name` is `domain` itself or a name under it."
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(name, domain), do: name == domain or String.ends_with?(name, "." <> domain)

  defp label?(label), do: match?({:ok, _hostname}, Hostname.parse(label))
end
