# Runs the server and its development OIDC provider. `dev/local.sh` reuses this setup and adds the
# real node process.
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
  require Logger

  alias Biot.Protocol.NodeId
  alias Biot.Server.Login.Settings
  alias Biot.Server.NodeConnections
  alias Biot.Server.Repo
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
    configure_server()

    endpoint =
      :biot_web
      |> Application.fetch_env!(BiotWeb.Endpoint)
      |> Keyword.put(:server, true)
      |> Keyword.update!(:http, &Keyword.put(&1, :port, http_port))

    Application.put_env(:biot_web, BiotWeb.Endpoint, endpoint)
    {:ok, _started} = Application.ensure_all_started(:biot_web)
    write_ready("server")
    await_node()

    IO.puts("""

    Biot is running.

      #{url}

    Open it and choose sign in. The provider approves the request and sends you back, so you
    arrive as #{developer_email()}. Then create a bearer token on the account page and save it:

      biot login #{url}

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

  defp configure_server do
    configure_database()
    configure_default_node()
    configure_control()
    configure_ssh()
  end

  defp configure_database do
    case System.get_env("BIOT_SERVER_DATABASE") do
      nil ->
        :ok

      path ->
        repo = Application.fetch_env!(:biot_server, Repo)
        Application.put_env(:biot_server, Repo, Keyword.put(repo, :database, path))
    end
  end

  defp configure_default_node do
    case System.get_env("BIOT_DEFAULT_NODE_ID") do
      nil ->
        :ok

      node_id ->
        {:ok, node_id} = NodeId.parse(node_id)
        Application.put_env(:biot_server, :default_node_id, node_id)
    end
  end

  defp configure_control do
    case System.get_env("BIOT_CONTROL_PORT") do
      nil ->
        :ok

      port ->
        Application.put_env(:biot_server, :control_port, parse_port!("BIOT_CONTROL_PORT", port))

        Application.put_env(:biot_server, :control_tls,
          certfile: required_env!("BIOT_CONTROL_CERTFILE"),
          keyfile: required_env!("BIOT_CONTROL_KEYFILE"),
          cacertfile: required_env!("BIOT_CONTROL_CACERTFILE")
        )
    end
  end

  defp configure_ssh do
    case System.get_env("BIOT_SSH_HOST_KEY_FILE") do
      nil ->
        :ok

      path ->
        Application.put_env(:biot_server, :ssh_host_key_file, path)

        Application.put_env(
          :biot_server,
          :ssh_advertised_host,
          required_env!("BIOT_SSH_ADVERTISED_HOST")
        )

        Application.put_env(
          :biot_server,
          :ssh_port,
          parse_port!("BIOT_SSH_PORT", required_env!("BIOT_SSH_PORT"))
        )
    end
  end

  defp await_node do
    case {System.get_env("BIOT_DEV_NODE_ID"), System.get_env("BIOT_DEV_READY_FILE")} do
      {node_id, ready_file} when is_binary(node_id) and is_binary(ready_file) ->
        {:ok, node_id} = NodeId.parse(node_id)

        Task.start(fn ->
          await_node(node_id, ready_file, System.monotonic_time(:millisecond) + 90_000)
        end)

      _missing ->
        :ok
    end
  end

  defp await_node(node_id, ready_file, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.warning("local node did not become ready before the deadline")
    else
      case NodeConnections.ready(node_id) do
        {:ok, _pid} ->
          write_ready("node", ready_file)

        {:error, :temporarily_unavailable} ->
          Process.sleep(100)
          await_node(node_id, ready_file, deadline)
      end
    end
  end

  defp write_ready(kind), do: write_ready(kind, System.get_env("BIOT_DEV_READY_FILE"))

  defp write_ready(kind, ready_file) when is_binary(ready_file) do
    File.mkdir_p!(Path.dirname(ready_file))
    File.write!(ready_file <> "." <> kind, "ready\n")
  end

  defp write_ready(_kind, nil), do: :ok

  defp required_env!(name), do: System.fetch_env!(name)

  defp parse_port!(name, value) do
    case Integer.parse(value) do
      {port, ""} when port > 0 and port < 65_536 -> port
      _other -> raise "#{name} must be a port number"
    end
  end

  defp developer_email, do: System.get_env("BIOT_DEV_EMAIL", "developer@example.test")
end

Dev.Stack.main()
