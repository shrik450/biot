import Config

# The node release reads this file at boot. Build support is not a setting: the release carries
# the Nix and agent sources it was built with, under the node app's `priv/build_support`.

logger_level = System.get_env("BIOT_LOG_LEVEL", "info")

logger_level =
  Enum.find(Logger.levels(), &(Atom.to_string(&1) == logger_level)) ||
    raise "BIOT_LOG_LEVEL must be one of #{inspect(Logger.levels())}; got #{inspect(logger_level)}"

config :logger, level: logger_level

alias Biot.Protocol.RegistrationId

required = fn name ->
  System.get_env(name) || raise "environment variable #{name} is missing"
end

integer = fn name, default, minimum ->
  case Integer.parse(System.get_env(name, Integer.to_string(default))) do
    {value, ""} when value >= minimum ->
      value

    _error ->
      kind = if minimum == 0, do: "a non-negative integer", else: "a positive integer"
      raise "#{name} must be #{kind}"
  end
end

# A cache list is whitespace separated, the same way Nix itself writes one.
list = fn name ->
  name |> required.() |> String.split(~r/\s+/, trim: true)
end

server_fingerprint = required.("BIOT_SERVER_FINGERPRINT")

unless Regex.match?(~r/\A[0-9a-f]{64}\z/, server_fingerprint) do
  raise "BIOT_SERVER_FINGERPRINT must be a lowercase SHA-256 fingerprint"
end

registration_id =
  case RegistrationId.parse(required.("BIOT_NODE_REGISTRATION_ID")) do
    {:ok, registration_id} -> registration_id
    {:error, _reason} -> raise "BIOT_NODE_REGISTRATION_ID must be a canonical UUID"
  end

data_root = required.("BIOT_NODE_DATA_ROOT")

unless Path.type(data_root) == :absolute and Path.expand(data_root) == data_root do
  raise "BIOT_NODE_DATA_ROOT must be an absolute canonical path"
end

uid_range_base = integer.("BIOT_NODE_UID_RANGE_BASE", 100_000, 0)

config :biot_node,
  data_root: data_root,
  uid_range_base: uid_range_base,
  uid_range_count: integer.("BIOT_NODE_UID_RANGE_COUNT", 1_024, 1),
  uid_range_limit: integer.("BIOT_NODE_UID_RANGE_LIMIT", uid_range_base + 65_536, 1),
  git_executable: System.get_env("BIOT_NODE_GIT", "git"),
  podman_executable: System.get_env("BIOT_NODE_PODMAN", "podman"),
  podman_network_command: System.get_env("BIOT_NODE_PODMAN_NETWORK_COMMAND", "slirp4netns"),
  flock_executable: System.get_env("BIOT_NODE_FLOCK", "flock"),
  setsid_executable: System.get_env("BIOT_NODE_SETSID", "setsid"),
  mkfifo_executable: System.get_env("BIOT_NODE_MKFIFO", "mkfifo"),
  head_executable: System.get_env("BIOT_NODE_HEAD", "head"),
  cat_executable: System.get_env("BIOT_NODE_CAT", "cat"),
  sleep_executable: System.get_env("BIOT_NODE_SLEEP", "sleep"),
  builder_image: required.("BIOT_NODE_BUILDER_IMAGE"),
  # Unset unless the operator runs a Git host the builder image's roots do not cover. It replaces
  # the fetch phase's trust store rather than adding to it, so the file must hold every authority
  # a fetch needs, public roots included. The fetch phase alone gets it.
  fetch_ca_bundle: System.get_env("BIOT_NODE_FETCH_CA_BUNDLE"),
  binary_cache_urls: list.("BIOT_NODE_BINARY_CACHE_URLS"),
  binary_cache_keys: list.("BIOT_NODE_BINARY_CACHE_KEYS"),
  nixpkgs_repository:
    System.get_env("BIOT_NODE_NIXPKGS_REPOSITORY", "https://github.com/NixOS/nixpkgs"),
  nixpkgs_ref: System.get_env("BIOT_NODE_NIXPKGS_REF", "nixos-unstable"),
  host_command_timeout_ms: integer.("BIOT_NODE_HOST_COMMAND_TIMEOUT_MS", 600_000, 1),
  host_command_max_output_bytes: integer.("BIOT_NODE_HOST_COMMAND_MAX_OUTPUT_BYTES", 256_000, 1),
  host_command_max_stderr_bytes: integer.("BIOT_NODE_HOST_COMMAND_MAX_STDERR_BYTES", 256_000, 1),
  worker_timeout_ms: integer.("BIOT_NODE_WORKER_TIMEOUT_MS", 3_600_000, 1),
  server_host: required.("BIOT_SERVER_HOST"),
  server_port: integer.("BIOT_SERVER_PORT", 4443, 1),
  server_fingerprint: server_fingerprint,
  registration_id: registration_id,
  tls: [
    certfile: required.("BIOT_NODE_CERTFILE"),
    keyfile: required.("BIOT_NODE_KEYFILE"),
    cacertfile: required.("BIOT_NODE_CACERTFILE")
  ],
  retry_budget: integer.("BIOT_NODE_RETRY_BUDGET", 5, 1),
  retry_backoff_min_ms: integer.("BIOT_NODE_RETRY_BACKOFF_MIN_MS", 2_000, 1),
  retry_backoff_max_ms: integer.("BIOT_NODE_RETRY_BACKOFF_MAX_MS", 300_000, 1),
  observation_interval_ms: integer.("BIOT_NODE_OBSERVATION_INTERVAL_MS", 30_000, 1),
  inspection_retry_ms: integer.("BIOT_NODE_INSPECTION_RETRY_MS", 15_000, 1),
  cancel_grace_ms: integer.("BIOT_NODE_CANCEL_GRACE_MS", 10_000, 1),
  controller_start_retry_ms: integer.("BIOT_NODE_CONTROLLER_START_RETRY_MS", 5_000, 1),
  container_events_retry_ms: integer.("BIOT_NODE_CONTAINER_EVENTS_RETRY_MS", 5_000, 1),
  diagnostic_max_entries_per_biot: integer.("BIOT_NODE_DIAGNOSTIC_MAX_ENTRIES_PER_BIOT", 5, 1),
  diagnostic_max_entry_bytes: integer.("BIOT_NODE_DIAGNOSTIC_MAX_ENTRY_BYTES", 65_536, 1),
  runtime_log_max_bytes: integer.("BIOT_NODE_RUNTIME_LOG_MAX_BYTES", 1_048_576, 1),
  heartbeat_interval_ms: integer.("BIOT_NODE_HEARTBEAT_INTERVAL_MS", 30_000, 1),
  heartbeat_timeout_ms: integer.("BIOT_NODE_HEARTBEAT_TIMEOUT_MS", 10_000, 1),
  reconnect_backoff_min_ms: integer.("BIOT_NODE_BACKOFF_MIN_MS", 250, 1),
  reconnect_backoff_max_ms: integer.("BIOT_NODE_BACKOFF_MAX_MS", 30_000, 1),
  max_frame_bytes: integer.("BIOT_MAX_FRAME_BYTES", 1_000_000, 1),
  max_staged_specs: integer.("BIOT_NODE_MAX_STAGED_SPECS", 1_000, 1),
  max_streams: integer.("BIOT_NODE_MAX_STREAMS", 128, 1),
  max_streams_per_biot: integer.("BIOT_NODE_MAX_STREAMS_PER_BIOT", 16, 1)
