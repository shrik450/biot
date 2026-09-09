import Config

alias Biot.Protocol.NodeId

default_node_id =
  case System.get_env("BIOT_DEFAULT_NODE_ID") do
    nil ->
      nil

    value ->
      case NodeId.parse(value) do
        {:ok, node_id} ->
          node_id

        {:error, _reason} ->
          raise "BIOT_DEFAULT_NODE_ID must be a canonical UUID"
      end
  end

config :biot_server, default_node_id: default_node_id

if config_env() in [:dev, :prod] do
  config :biot_server,
    node_registrations_file: System.get_env("BIOT_NODE_REGISTRATIONS")
end

if config_env() == :prod and System.get_env("RELEASE_NAME") != "node" do
  integer_env = fn name, default ->
    case Integer.parse(System.get_env(name, Integer.to_string(default))) do
      {value, ""} when value > 0 -> value
      _error -> raise "#{name} must be a positive integer"
    end
  end

  required_env = fn name ->
    System.get_env(name) || raise "environment variable #{name} is missing"
  end

  config :biot_server,
    control_port: integer_env.("BIOT_CONTROL_PORT", 4443),
    control_tls: [
      certfile: required_env.("BIOT_CONTROL_CERTFILE"),
      keyfile: required_env.("BIOT_CONTROL_KEYFILE"),
      cacertfile: required_env.("BIOT_CONTROL_CACERTFILE")
    ],
    handshake_timeout_ms: integer_env.("BIOT_HANDSHAKE_TIMEOUT_MS", 10_000),
    heartbeat_interval_ms: integer_env.("BIOT_HEARTBEAT_INTERVAL_MS", 30_000),
    heartbeat_timeout_ms: integer_env.("BIOT_HEARTBEAT_TIMEOUT_MS", 10_000),
    diagnostic_timeout_ms: integer_env.("BIOT_DIAGNOSTIC_TIMEOUT_MS", 10_000),
    diagnostic_max_bytes: integer_env.("BIOT_DIAGNOSTIC_MAX_BYTES", 256_000),
    max_frame_bytes: integer_env.("BIOT_MAX_FRAME_BYTES", 1_000_000)

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      """

  port = String.to_integer(System.get_env("PORT", "4000"))

  config :biot_web, BiotWeb.Endpoint,
    url: [host: host, port: 443],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end

if config_env() == :prod and System.get_env("RELEASE_NAME") != "server" do
  node_integer_env = fn name, default ->
    case Integer.parse(System.get_env(name, Integer.to_string(default))) do
      {value, ""} when value > 0 -> value
      _error -> raise "#{name} must be a positive integer"
    end
  end

  node_required_env = fn name ->
    System.get_env(name) || raise "environment variable #{name} is missing"
  end

  node_fingerprint = node_required_env.("BIOT_SERVER_FINGERPRINT")

  unless Regex.match?(~r/\A[0-9a-f]{64}\z/, node_fingerprint) do
    raise "BIOT_SERVER_FINGERPRINT must be a lowercase SHA-256 fingerprint"
  end

  registration_id = node_required_env.("BIOT_NODE_REGISTRATION_ID")

  case Biot.Protocol.RegistrationId.parse(registration_id) do
    {:ok, registration_id} ->
      config :biot_node,
        server_host: node_required_env.("BIOT_SERVER_HOST"),
        server_port: node_integer_env.("BIOT_SERVER_PORT", 4443),
        server_fingerprint: node_fingerprint,
        registration_id: registration_id,
        tls: [
          certfile: node_required_env.("BIOT_NODE_CERTFILE"),
          keyfile: node_required_env.("BIOT_NODE_KEYFILE"),
          cacertfile: node_required_env.("BIOT_NODE_CACERTFILE")
        ],
        heartbeat_interval_ms: node_integer_env.("BIOT_NODE_HEARTBEAT_INTERVAL_MS", 30_000),
        heartbeat_timeout_ms: node_integer_env.("BIOT_NODE_HEARTBEAT_TIMEOUT_MS", 10_000),
        reconnect_backoff_min_ms: node_integer_env.("BIOT_NODE_BACKOFF_MIN_MS", 250),
        reconnect_backoff_max_ms: node_integer_env.("BIOT_NODE_BACKOFF_MAX_MS", 30_000)

    {:error, _reason} ->
      raise "BIOT_NODE_REGISTRATION_ID must be a canonical UUID"
  end
end
