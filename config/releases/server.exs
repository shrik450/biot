import Config

# The server release reads this file at boot. Every setting is parsed here, so a release with a
# bad setting stops before it serves anything.

logger_level = System.get_env("BIOT_LOG_LEVEL", "info")

logger_level =
  Enum.find(Logger.levels(), &(Atom.to_string(&1) == logger_level)) ||
    raise "BIOT_LOG_LEVEL must be one of #{inspect(Logger.levels())}; got #{inspect(logger_level)}"

config :logger, level: logger_level

alias Biot.Protocol.NodeId
alias Biot.Protocol.Port
alias Biot.Server.DomainName
alias Biot.Server.Login.Settings, as: LoginSettings
alias BiotWeb.ClientAddress

required = fn name ->
  System.get_env(name) || raise "environment variable #{name} is missing"
end

positive_integer = fn name, default ->
  case Integer.parse(System.get_env(name, Integer.to_string(default))) do
    {value, ""} when value > 0 -> value
    _error -> raise "#{name} must be a positive integer"
  end
end

port = fn name ->
  case Port.parse(required.(name)) do
    {:ok, port} -> port.value
    {:error, _reason} -> raise "#{name} must be a valid TCP port"
  end
end

absolute_path = fn name ->
  path = required.(name)

  if Path.type(path) == :absolute,
    do: path,
    else: raise("#{name} must be an absolute path")
end

domain_name = fn name ->
  case DomainName.parse(required.(name)) do
    {:ok, domain} -> domain
    {:error, :invalid_format} -> raise "#{name} must be a lowercase DNS name"
  end
end

control_host = domain_name.("PHX_HOST")
publication_domain = domain_name.("BIOT_SERVER_PUBLICATION_DOMAIN")

if DomainName.within?(control_host, publication_domain) do
  raise "PHX_HOST must not be BIOT_SERVER_PUBLICATION_DOMAIN or a name under it, " <>
          "because every preview hostname is a name under that domain"
end

oidc =
  case LoginSettings.parse(
         required.("BIOT_OIDC_ISSUER"),
         required.("BIOT_OIDC_CLIENT_ID"),
         required.("BIOT_OIDC_CLIENT_SECRET"),
         control_host
       ) do
    {:ok, settings} ->
      settings

    {:error, :insecure_issuer} ->
      raise "BIOT_OIDC_ISSUER must be an https URL"

    {:error, :invalid_issuer} ->
      raise "BIOT_OIDC_ISSUER must be the provider's issuer URL"

    {:error, :empty_client_credentials} ->
      raise "BIOT_OIDC_CLIENT_ID and BIOT_OIDC_CLIENT_SECRET must not be empty"
  end

default_node_id =
  case System.get_env("BIOT_DEFAULT_NODE_ID") do
    nil ->
      nil

    value ->
      case NodeId.parse(value) do
        {:ok, node_id} -> node_id
        {:error, _reason} -> raise "BIOT_DEFAULT_NODE_ID must be a canonical UUID"
      end
  end

trusted_edge_peers =
  case System.get_env("BIOT_TRUSTED_EDGE_PEERS") do
    nil ->
      []

    value ->
      case ClientAddress.parse_peers(value) do
        {:ok, peers} ->
          peers

        {:error, {:invalid_peer, entry}} ->
          raise "BIOT_TRUSTED_EDGE_PEERS entry #{inspect(entry)} is not an IP address"
      end
  end

config :biot_server, Biot.Server.Repo, database: absolute_path.("BIOT_SERVER_DATABASE")

config :biot_server,
  default_node_id: default_node_id,
  oidc: oidc,
  control_host: control_host,
  node_registrations_file: System.get_env("BIOT_NODE_REGISTRATIONS"),
  disabled_principals_file: System.get_env("BIOT_DISABLED_PRINCIPALS"),
  publication_domain: publication_domain,
  ssh_advertised_host: required.("BIOT_SSH_ADVERTISED_HOST"),
  ssh_port: port.("BIOT_SSH_PORT"),
  ssh_host_key_file: absolute_path.("BIOT_SSH_HOST_KEY_FILE"),
  control_port: positive_integer.("BIOT_CONTROL_PORT", 4443),
  control_session_lifetime_ms: positive_integer.("BIOT_SESSION_LIFETIME_HOURS", 168) * 3_600_000,
  credential_max_lifetime_ms:
    positive_integer.("BIOT_CREDENTIAL_MAX_LIFETIME_DAYS", 90) * 86_400_000,
  control_tls: [
    certfile: required.("BIOT_CONTROL_CERTFILE"),
    keyfile: required.("BIOT_CONTROL_KEYFILE"),
    cacertfile: required.("BIOT_CONTROL_CACERTFILE")
  ],
  handshake_timeout_ms: positive_integer.("BIOT_HANDSHAKE_TIMEOUT_MS", 10_000),
  heartbeat_interval_ms: positive_integer.("BIOT_HEARTBEAT_INTERVAL_MS", 30_000),
  heartbeat_timeout_ms: positive_integer.("BIOT_HEARTBEAT_TIMEOUT_MS", 10_000),
  desired_sweep_interval_ms: positive_integer.("BIOT_DESIRED_SWEEP_INTERVAL_MS", 60_000),
  auth_check_interval_ms: positive_integer.("BIOT_AUTH_CHECK_INTERVAL_MS", 60_000),
  node_request_timeout_ms: positive_integer.("BIOT_NODE_REQUEST_TIMEOUT_MS", 10_000),
  node_response_max_bytes: positive_integer.("BIOT_NODE_RESPONSE_MAX_BYTES", 256_000),
  stream_open_timeout_ms: positive_integer.("BIOT_STREAM_OPEN_TIMEOUT_MS", 30_000),
  max_frame_bytes: positive_integer.("BIOT_MAX_FRAME_BYTES", 1_000_000),
  preview_request_max_bytes: positive_integer.("BIOT_PREVIEW_REQUEST_MAX_BYTES", 8_000_000),
  preview_request_chunk_bytes: positive_integer.("BIOT_PREVIEW_REQUEST_CHUNK_BYTES", 65_536),
  preview_head_max_bytes: positive_integer.("BIOT_PREVIEW_HEAD_MAX_BYTES", 65_536),
  preview_exchange_timeout_ms: positive_integer.("BIOT_PREVIEW_EXCHANGE_TIMEOUT_MS", 30_000),
  preview_handshake_timeout_ms: positive_integer.("BIOT_PREVIEW_HANDSHAKE_TIMEOUT_MS", 10_000)

config :biot_web, trusted_edge_peers: trusted_edge_peers

config :biot_web, BiotWeb.Endpoint,
  # The edge terminates TLS, so this URL is the control origin that browsers send in `Origin`.
  url: [scheme: "https", host: control_host, port: 443],
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: positive_integer.("PORT", 4000)],
  secret_key_base: required.("SECRET_KEY_BASE"),
  server: true
