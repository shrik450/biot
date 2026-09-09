defmodule Biot.Protocol.RepositorySource do
  @moduledoc "A credential-free Git repository URL."

  @enforce_keys [:url]
  defstruct [:url]

  @type t :: %__MODULE__{url: String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format | :embedded_credentials}
  def parse(value) when is_binary(value) do
    cond do
      not String.valid?(value) or Regex.match?(~r/\s/u, value) or String.contains?(value, "#") ->
        {:error, :invalid_format}

      scp_like?(value) ->
        {:ok, %__MODULE__{url: value}}

      true ->
        parse_uri(value)
    end
  end

  def parse(_value), do: {:error, :invalid_format}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{url: url}), do: url

  defp parse_uri(value) do
    uri = URI.parse(value)

    with :ok <- validate_scheme(uri.scheme),
         :ok <- validate_userinfo(uri.scheme, uri.userinfo),
         :ok <- validate_host(uri),
         :ok <- validate_query(uri.query) do
      {:ok, %__MODULE__{url: value}}
    end
  end

  defp validate_scheme(scheme) when scheme in ["https", "ssh"], do: :ok
  defp validate_scheme(_scheme), do: {:error, :invalid_format}

  defp validate_userinfo("https", userinfo) when not is_nil(userinfo),
    do: {:error, :embedded_credentials}

  defp validate_userinfo(_scheme, ""), do: {:error, :embedded_credentials}

  defp validate_userinfo(_scheme, userinfo) when is_binary(userinfo) do
    if String.contains?(URI.decode(userinfo), ":") do
      {:error, :embedded_credentials}
    else
      :ok
    end
  end

  defp validate_userinfo(_scheme, nil), do: :ok

  defp validate_host(%URI{host: host, path: path})
       when is_binary(host) and host != "" and path not in [nil, ""],
       do: :ok

  defp validate_host(_uri), do: {:error, :invalid_format}

  defp validate_query(nil), do: :ok
  defp validate_query(_query), do: {:error, :invalid_format}

  defp scp_like?(value) do
    Regex.match?(~r{\Agit@[^:/\s]+:[^\s].*\z}u, value)
  end
end

defimpl String.Chars, for: Biot.Protocol.RepositorySource do
  def to_string(value), do: Biot.Protocol.RepositorySource.to_string(value)
end
