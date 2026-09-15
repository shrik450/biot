defmodule Biot.Server.Login.Settings do
  @moduledoc """
  The OIDC client settings, parsed once when the release starts.

  The issuer must be HTTPS. The provider's discovery document and signing keys decide who every
  login is, so an issuer reached over plain HTTP would let the network decide instead.
  """

  @derive {Inspect, except: [:client_secret]}
  @enforce_keys [:issuer, :client_id, :client_secret, :redirect_uri]
  defstruct [:issuer, :client_id, :client_secret, :redirect_uri]

  @type t :: %__MODULE__{
          issuer: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          redirect_uri: String.t()
        }

  @doc "Parses the operator's provider settings for a server whose control host is `control_host`."
  @spec parse(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, :insecure_issuer | :invalid_issuer | :empty_client_credentials}
  def parse(issuer, client_id, client_secret, control_host) do
    with :ok <- check_issuer(issuer),
         :ok <- check_client(client_id, client_secret) do
      {:ok,
       %__MODULE__{
         issuer: issuer,
         client_id: client_id,
         client_secret: client_secret,
         redirect_uri: "https://#{control_host}/login/callback"
       }}
    end
  end

  defp check_issuer(issuer) do
    case URI.new(issuer) do
      {:ok, %URI{scheme: "https", host: host}} when host not in [nil, ""] -> :ok
      {:ok, %URI{scheme: "http"}} -> {:error, :insecure_issuer}
      _other -> {:error, :invalid_issuer}
    end
  end

  defp check_client(client_id, client_secret) do
    if client_id != "" and client_secret != "",
      do: :ok,
      else: {:error, :empty_client_credentials}
  end
end
