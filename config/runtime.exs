import Config

alias Biot.Protocol.{NodeId, Port}

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
    node_registrations_file: System.get_env("BIOT_NODE_REGISTRATIONS"),
    disabled_principals_file: System.get_env("BIOT_DISABLED_PRINCIPALS")
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

  port_env = fn name ->
    case Port.parse(required_env.(name)) do
      {:ok, port} -> port.value
      {:error, _reason} -> raise "#{name} must be a valid TCP port"
    end
  end

  config :biot_server,
    publication_domain: required_env.("BIOT_SERVER_PUBLICATION_DOMAIN"),
    ssh_advertised_host: required_env.("BIOT_SSH_ADVERTISED_HOST"),
    ssh_port: port_env.("BIOT_SSH_PORT"),
    control_port: integer_env.("BIOT_CONTROL_PORT", 4443),
    control_session_lifetime_ms: integer_env.("BIOT_SESSION_LIFETIME_HOURS", 168) * 3_600_000,
    credential_max_lifetime_ms:
      integer_env.("BIOT_CREDENTIAL_MAX_LIFETIME_DAYS", 90) * 86_400_000,
    control_tls: [
      certfile: required_env.("BIOT_CONTROL_CERTFILE"),
      keyfile: required_env.("BIOT_CONTROL_KEYFILE"),
      cacertfile: required_env.("BIOT_CONTROL_CACERTFILE")
    ],
    handshake_timeout_ms: integer_env.("BIOT_HANDSHAKE_TIMEOUT_MS", 10_000),
    heartbeat_interval_ms: integer_env.("BIOT_HEARTBEAT_INTERVAL_MS", 30_000),
    heartbeat_timeout_ms: integer_env.("BIOT_HEARTBEAT_TIMEOUT_MS", 10_000),
    desired_sweep_interval_ms: integer_env.("BIOT_DESIRED_SWEEP_INTERVAL_MS", 60_000),
    node_request_timeout_ms: integer_env.("BIOT_NODE_REQUEST_TIMEOUT_MS", 10_000),
    node_response_max_bytes: integer_env.("BIOT_NODE_RESPONSE_MAX_BYTES", 256_000),
    stream_open_timeout_ms: integer_env.("BIOT_STREAM_OPEN_TIMEOUT_MS", 30_000),
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
  node_integer_env = fn name, default, minimum ->
    case Integer.parse(System.get_env(name, Integer.to_string(default))) do
      {value, ""} when value >= minimum ->
        value

      _error ->
        kind = if minimum == 0, do: "a non-negative integer", else: "a positive integer"
        raise "#{name} must be #{kind}"
    end
  end

  node_required_env = fn name ->
    System.get_env(name) || raise "environment variable #{name} is missing"
  end

  # A cache list is whitespace separated, the same way Nix itself writes one.
  node_list_env = fn name ->
    name |> node_required_env.() |> String.split(~r/\s+/, trim: true)
  end

  node_fingerprint = node_required_env.("BIOT_SERVER_FINGERPRINT")

  unless Regex.match?(~r/\A[0-9a-f]{64}\z/, node_fingerprint) do
    raise "BIOT_SERVER_FINGERPRINT must be a lowercase SHA-256 fingerprint"
  end

  registration_id = node_required_env.("BIOT_NODE_REGISTRATION_ID")

  data_root = node_required_env.("BIOT_NODE_DATA_ROOT")

  unless Path.type(data_root) == :absolute and Path.expand(data_root) == data_root do
    raise "BIOT_NODE_DATA_ROOT must be an absolute canonical path"
  end

  uid_range_base = node_integer_env.("BIOT_NODE_UID_RANGE_BASE", 100_000, 0)

  case Biot.Protocol.RegistrationId.parse(registration_id) do
    {:ok, registration_id} ->
      config :biot_node,
        data_root: data_root,
        uid_range_base: uid_range_base,
        uid_range_count: node_integer_env.("BIOT_NODE_UID_RANGE_COUNT", 1_024, 1),
        uid_range_limit:
          node_integer_env.("BIOT_NODE_UID_RANGE_LIMIT", uid_range_base + 65_536, 1),
        git_executable: System.get_env("BIOT_NODE_GIT", "git"),
        podman_executable: System.get_env("BIOT_NODE_PODMAN", "podman"),
        podman_network_command: System.get_env("BIOT_NODE_PODMAN_NETWORK_COMMAND", "slirp4netns"),
        flock_executable: System.get_env("BIOT_NODE_FLOCK", "flock"),
        setsid_executable: System.get_env("BIOT_NODE_SETSID", "setsid"),
        mkfifo_executable: System.get_env("BIOT_NODE_MKFIFO", "mkfifo"),
        head_executable: System.get_env("BIOT_NODE_HEAD", "head"),
        cat_executable: System.get_env("BIOT_NODE_CAT", "cat"),
        sleep_executable: System.get_env("BIOT_NODE_SLEEP", "sleep"),
        builder_image: node_required_env.("BIOT_NODE_BUILDER_IMAGE"),
        build_support_dir: node_required_env.("BIOT_NODE_BUILD_SUPPORT_DIR"),
        # Unset unless the operator runs a Git host the builder image's roots do not cover. It
        # replaces the fetch phase's trust store rather than adding to it, so the file must hold
        # every authority a fetch needs, public roots included. The fetch phase alone gets it.
        fetch_ca_bundle: System.get_env("BIOT_NODE_FETCH_CA_BUNDLE"),
        binary_cache_urls: node_list_env.("BIOT_NODE_BINARY_CACHE_URLS"),
        binary_cache_keys: node_list_env.("BIOT_NODE_BINARY_CACHE_KEYS"),
        nixpkgs_repository:
          System.get_env("BIOT_NODE_NIXPKGS_REPOSITORY", "https://github.com/NixOS/nixpkgs"),
        nixpkgs_ref: System.get_env("BIOT_NODE_NIXPKGS_REF", "nixos-unstable"),
        host_command_timeout_ms:
          node_integer_env.("BIOT_NODE_HOST_COMMAND_TIMEOUT_MS", 600_000, 1),
        host_command_max_output_bytes:
          node_integer_env.("BIOT_NODE_HOST_COMMAND_MAX_OUTPUT_BYTES", 256_000, 1),
        host_command_max_stderr_bytes:
          node_integer_env.("BIOT_NODE_HOST_COMMAND_MAX_STDERR_BYTES", 256_000, 1),
        worker_timeout_ms: node_integer_env.("BIOT_NODE_WORKER_TIMEOUT_MS", 3_600_000, 1),
        server_host: node_required_env.("BIOT_SERVER_HOST"),
        server_port: node_integer_env.("BIOT_SERVER_PORT", 4443, 1),
        server_fingerprint: node_fingerprint,
        registration_id: registration_id,
        tls: [
          certfile: node_required_env.("BIOT_NODE_CERTFILE"),
          keyfile: node_required_env.("BIOT_NODE_KEYFILE"),
          cacertfile: node_required_env.("BIOT_NODE_CACERTFILE")
        ],
        retry_budget: node_integer_env.("BIOT_NODE_RETRY_BUDGET", 5, 1),
        retry_backoff_min_ms: node_integer_env.("BIOT_NODE_RETRY_BACKOFF_MIN_MS", 2_000, 1),
        retry_backoff_max_ms: node_integer_env.("BIOT_NODE_RETRY_BACKOFF_MAX_MS", 300_000, 1),
        observation_interval_ms:
          node_integer_env.("BIOT_NODE_OBSERVATION_INTERVAL_MS", 30_000, 1),
        inspection_retry_ms: node_integer_env.("BIOT_NODE_INSPECTION_RETRY_MS", 15_000, 1),
        cancel_grace_ms: node_integer_env.("BIOT_NODE_CANCEL_GRACE_MS", 10_000, 1),
        controller_start_retry_ms:
          node_integer_env.("BIOT_NODE_CONTROLLER_START_RETRY_MS", 5_000, 1),
        container_events_retry_ms:
          node_integer_env.("BIOT_NODE_CONTAINER_EVENTS_RETRY_MS", 5_000, 1),
        diagnostic_max_entries_per_biot:
          node_integer_env.("BIOT_NODE_DIAGNOSTIC_MAX_ENTRIES_PER_BIOT", 5, 1),
        diagnostic_max_entry_bytes:
          node_integer_env.("BIOT_NODE_DIAGNOSTIC_MAX_ENTRY_BYTES", 65_536, 1),
        runtime_log_max_bytes: node_integer_env.("BIOT_NODE_RUNTIME_LOG_MAX_BYTES", 1_048_576, 1),
        heartbeat_interval_ms: node_integer_env.("BIOT_NODE_HEARTBEAT_INTERVAL_MS", 30_000, 1),
        heartbeat_timeout_ms: node_integer_env.("BIOT_NODE_HEARTBEAT_TIMEOUT_MS", 10_000, 1),
        reconnect_backoff_min_ms: node_integer_env.("BIOT_NODE_BACKOFF_MIN_MS", 250, 1),
        reconnect_backoff_max_ms: node_integer_env.("BIOT_NODE_BACKOFF_MAX_MS", 30_000, 1),
        max_frame_bytes: node_integer_env.("BIOT_MAX_FRAME_BYTES", 1_000_000, 1),
        max_staged_specs: node_integer_env.("BIOT_NODE_MAX_STAGED_SPECS", 1_000, 1),
        max_streams: node_integer_env.("BIOT_NODE_MAX_STREAMS", 128, 1),
        max_streams_per_biot: node_integer_env.("BIOT_NODE_MAX_STREAMS_PER_BIOT", 16, 1)

    {:error, _reason} ->
      raise "BIOT_NODE_REGISTRATION_ID must be a canonical UUID"
  end
end
