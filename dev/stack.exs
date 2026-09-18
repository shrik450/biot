# Runs a complete Biot on this machine: the server, and an OIDC provider to sign in through.
#
#   MIX_ENV=dev mix run --no-start dev/stack.exs
#
# Biot gets identity from an OIDC provider and has no other way in, so a checkout with no provider
# cannot be signed in to at all. This script supplies one. It is the same provider the web
# integration checks use: a real OIDC service with discovery, a JWKS endpoint, RS256 ID tokens and
# PKCE, listening on loopback. It approves whoever asks, because choosing who exists is the
# provider's job and here there is one developer.
#
# The provider lives under test support and is loaded by path, so no release can contain a service
# that signs its own identity tokens.
#
# It holds until killed.

Code.require_file("../apps/biot_web/test/support/oidc_peer.ex", __DIR__)

defmodule Dev.Stack do
  alias Biot.Server.Login.Settings
  alias BiotWeb.OidcPeer

  def main do
    http_port = port_from_env()
    control_host = Application.fetch_env!(:biot_server, :control_host)
    url = "http://#{control_host}:#{http_port}"

    {:ok, peer} =
      OidcPeer.start_link(user: %{subject: "dev", email: developer_email(), name: "Developer"})

    # The endpoint's port has to be settled before the provider is configured: the redirect URI is
    # registered with the provider, and a provider that disagrees about it refuses the exchange.
    %Settings{} = settings = OidcPeer.configuration(peer, "#{url}/login/callback")
    Application.put_env(:biot_server, :oidc, settings)

    endpoint =
      :biot_web
      |> Application.fetch_env!(BiotWeb.Endpoint)
      |> Keyword.put(:server, true)
      |> Keyword.update!(:http, &Keyword.put(&1, :port, http_port))

    Application.put_env(:biot_web, BiotWeb.Endpoint, endpoint)
    {:ok, _started} = Application.ensure_all_started(:biot_web)

    IO.puts("""

    Biot is running.

      #{url}

    Open it and choose sign in. The provider approves the request and sends you back, so you
    arrive as #{developer_email()}. Then create a bearer token on the account page and save it:

      biot login #{url}

    Creating a Biot needs a node, which this script does not start. Without one, create stops with
    "the server has no default node".

    Stop with Ctrl-C.
    """)

    Process.sleep(:infinity)
  end

  defp port_from_env do
    case Integer.parse(System.get_env("PORT", "4000")) do
      {port, ""} when port > 0 and port < 65_536 -> port
      _other -> raise "PORT must be a port number"
    end
  end

  defp developer_email, do: System.get_env("BIOT_DEV_EMAIL", "developer@example.test")
end

Dev.Stack.main()
