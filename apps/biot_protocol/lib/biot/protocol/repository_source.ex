defmodule Biot.Protocol.RepositorySource do
  @moduledoc """
  A credential-free HTTPS Git repository URL.

  HTTPS is the only scheme Biot fetches over, so it is the only scheme that parses. Rejecting the
  rest here is what makes the rule hold everywhere: a local path, an `ssh://` URL, or an
  `scp`-like address that never becomes a value cannot reach a clone, a pin, or a layer fetch.
  """

  alias Biot.Protocol.Limits

  @enforce_keys [:url]
  defstruct [:url]

  @type t :: %__MODULE__{url: String.t()}

  @spec parse(term()) ::
          {:ok, t()}
          | {:error, :invalid_format | :embedded_credentials | :repository_url_too_long}
  def parse(value) when is_binary(value) do
    cond do
      byte_size(value) > Limits.max_repository_url_bytes() ->
        {:error, :repository_url_too_long}

      not String.valid?(value) or Regex.match?(~r/\s/u, value) or String.contains?(value, "#") ->
        {:error, :invalid_format}

      true ->
        parse_uri(value)
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{url: url}), do: url

  @doc """
  The scheme, host, and port this repository is served from, without its path.

  A transport reports a failure against the origin it was talking to as often as against the whole
  URL, so recognizing which source a message is about needs both forms.
  """
  @spec origin(t()) :: String.t()
  def origin(%__MODULE__{url: url}) do
    uri = URI.parse(url)
    port = if uri.port in [nil, 443], do: "", else: ":#{uri.port}"
    "https://" <> uri.host <> port
  end

  defp parse_uri(value) do
    uri = URI.parse(value)

    with :ok <- validate_scheme(uri.scheme),
         :ok <- validate_userinfo(uri.userinfo),
         :ok <- validate_host(uri),
         :ok <- validate_query(uri.query) do
      {:ok, %__MODULE__{url: value}}
    end
  end

  defp validate_scheme("https"), do: :ok
  defp validate_scheme(_scheme), do: {:error, :invalid_format}

  # An HTTPS URL carrying any userinfo is carrying a credential, whether or not it has a password.
  defp validate_userinfo(nil), do: :ok
  defp validate_userinfo(_userinfo), do: {:error, :embedded_credentials}

  defp validate_host(%URI{host: host, path: path})
       when is_binary(host) and host != "" and path not in [nil, ""],
       do: :ok

  defp validate_host(_uri), do: {:error, :invalid_format}

  defp validate_query(nil), do: :ok
  defp validate_query(_query), do: {:error, :invalid_format}
end

defimpl String.Chars, for: Biot.Protocol.RepositorySource do
  def to_string(value), do: Biot.Protocol.RepositorySource.to_string(value)
end
