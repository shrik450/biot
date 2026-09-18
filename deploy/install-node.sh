#!/usr/bin/env bash
#
# install-node.sh — bring up a Biot node host with one idempotent command.
#
# It performs the "## Node" host setup from docs/deployment.md: it checks the host first, creates
# the service account and its paths, reads the subordinate UID/GID range the host assigned (never
# a base the operator guesses), copies the built node release, pulls the pinned builder image,
# writes the release environment, and installs and starts the systemd unit. Run it again and it
# only fills in what is missing.
#
# Run it as root on the node host:
#
#   sudo deploy/install-node.sh --node-name biot-node-1 --server-host biot.example.com \
#     --server-fingerprint <64 hex> --registration-id <uuid>
#
# Give it --check to run only the preflight and stop; it makes no changes in that mode.
#
# The node's control-link certificate, its key, and the CA are the operator's to issue on the
# machine that holds the authority; this script expects them in --certs-dir and never reads the
# authority's private key.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "$script_dir/.." && pwd)
config_file="$repo_dir/config/config.exs"

service_user=biot
release_dir=/opt/biot/node
source_release="$repo_dir/_build/prod/rel/node"
data_root=/var/lib/biot/node
certs_dir=/etc/biot/certs
env_file=/etc/biot/node.env
unit_output=/etc/biot/biot-node.service
unit_name=biot-node.service
systemd_dir=/etc/systemd/system
node_name=
server_host=
server_port=4443
server_fingerprint=
registration_id=
builder_image=
binary_cache_urls=
binary_cache_keys=
# The node's whole subordinate span; the release default is BASE + 65536.
uid_span=65536
uid_range_count=1024
uid_base=
uid_limit=
mode=install
start_service=1
force_env=0
force_unit=0

usage() {
  cat <<'EOF'
usage: install-node.sh [options]

Runs the Biot node host setup on this machine. An install needs at least --node-name,
--server-host, --server-fingerprint, and --registration-id.

Options:
  --check                  Run the preflight checks only and stop. Makes no changes.
  --no-start               Install and enable the unit but do not start it.
  --service-user NAME      Service account (default: biot).
  --release-dir DIR        Where the node runs from (default: /opt/biot/node).
  --source-release DIR     Built release to copy (default: <repo>/_build/prod/rel/node).
  --data-root DIR          Node data root (default: /var/lib/biot/node).
  --certs-dir DIR          Directory with ca.pem and the node certificate and key
                           (default: /etc/biot/certs).
  --env-file FILE          Release environment file (default: /etc/biot/node.env).
  --unit-output FILE       Where to write the unit for the operator to read and edit
                           (default: /etc/biot/biot-node.service).
  --node-name NAME         Node name used for its certificate files and registration.
  --server-host HOST       Server host the node dials for control.
  --server-port PORT       Server control port (default: 4443).
  --server-fingerprint HEX Lowercase SHA-256 fingerprint of the server identity.
  --registration-id UUID   Registration ID present in the server's enrollment file.
  --builder-image IMAGE    Pinned builder image; default read from config/config.exs.
  --binary-cache-urls URLS Whitespace-separated Nix cache endpoints.
  --binary-cache-keys KEYS Whitespace-separated trusted Nix cache public keys.
  --force-env              Regenerate --env-file even if it exists.
  --force-unit             Regenerate --unit-output even if it exists.
  -h, --help               Show this help.

The UID base is read from the service account's /etc/subuid entry. There is no flag to set it:
a base that disagrees with the host is the failure this script exists to prevent.
EOF
}

say() { printf '%s\n' "$*"; }
good() { printf '  ok      %s\n' "$1"; }
todo() { printf '  todo    %s\n           fix: %s\n' "$1" "$2"; }
block() {
  printf '  BLOCK   %s\n           fix: %s\n' "$1" "$2"
  blockers+=("$1")
}
die() {
  printf 'install-node: %s\n' "$*" >&2
  exit 1
}
need_value() { (($# >= 2)) || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --check) mode=check; shift ;;
    --no-start) start_service=0; shift ;;
    --service-user) need_value "$@"; service_user=$2; shift 2 ;;
    --release-dir) need_value "$@"; release_dir=$2; shift 2 ;;
    --source-release) need_value "$@"; source_release=$2; shift 2 ;;
    --data-root) need_value "$@"; data_root=$2; shift 2 ;;
    --certs-dir) need_value "$@"; certs_dir=$2; shift 2 ;;
    --env-file) need_value "$@"; env_file=$2; shift 2 ;;
    --unit-output) need_value "$@"; unit_output=$2; shift 2 ;;
    --node-name) need_value "$@"; node_name=$2; shift 2 ;;
    --server-host) need_value "$@"; server_host=$2; shift 2 ;;
    --server-port) need_value "$@"; server_port=$2; shift 2 ;;
    --server-fingerprint) need_value "$@"; server_fingerprint=$2; shift 2 ;;
    --registration-id) need_value "$@"; registration_id=$2; shift 2 ;;
    --builder-image) need_value "$@"; builder_image=$2; shift 2 ;;
    --binary-cache-urls) need_value "$@"; binary_cache_urls=$2; shift 2 ;;
    --binary-cache-keys) need_value "$@"; binary_cache_keys=$2; shift 2 ;;
    --force-env) force_env=1; shift ;;
    --force-unit) force_unit=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# The pinned builder image and the Nix cache settings live in the project's configuration. Read
# them from there when they are not given, so the node uses the same pin the release was built
# with. A missing config file or key leaves the flag empty and the preflight names it.
cfg_string() {
  grep -A1 -- "$1:" "$config_file" 2>/dev/null | grep -oE "$2" | head -1
}

cfg_list() {
  grep -m1 -- "$1:" "$config_file" 2>/dev/null |
    grep -oE '"[^"]*"' | tr -d '"' | tr '\n' ' ' | sed 's/ *$//'
}

if [[ -z $builder_image ]]; then
  builder_image=$(cfg_string builder_image '[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}' || true)
fi
if [[ -z $binary_cache_urls ]]; then
  binary_cache_urls=$(cfg_list binary_cache_urls || true)
fi
if [[ -z $binary_cache_keys ]]; then
  binary_cache_keys=$(cfg_list binary_cache_keys || true)
fi
: "${binary_cache_urls:=https://cache.nixos.org}"
: "${binary_cache_keys:=cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=}"

node_cert="$certs_dir/node-$node_name-cert.pem"
node_key="$certs_dir/node-$node_name-key.pem"
node_ca="$certs_dir/ca.pem"

user_exists() { id -u "$1" >/dev/null 2>&1; }
current_user=$(id -un)

run_as_user() {
  local user=$1
  shift
  if [[ $current_user == "$user" ]]; then
    "$@"
  else
    runuser -u "$user" -- "$@"
  fi
}

subid_start() { awk -F: -v u="$1" '$1 == u { print $2; exit }' "$2" 2>/dev/null || true; }
subid_count() { awk -F: -v u="$1" '$1 == u { print $3; exit }' "$2" 2>/dev/null || true; }

canonical_path() {
  case $1 in
    /) return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  case $1 in
    */ | *//* | */./* | */../* | */. | */..) return 1 ;;
  esac
  return 0
}

valid_service_user() { [[ $1 =~ ^[a-z_][a-z0-9_-]*$ ]]; }
valid_node_name() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#1} -le 63 ]]; }
valid_fingerprint() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
valid_uuid() { [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }

blockers=()
todos=()

check_cgroup() {
  local filesystem
  filesystem=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)
  if [[ $filesystem == cgroup2fs ]]; then
    good "cgroup v2 is mounted at /sys/fs/cgroup"
  else
    block "cgroup v2 is not mounted at /sys/fs/cgroup (found '${filesystem:-nothing}')" \
      "boot a kernel with cgroup v2; rootless Podman needs it"
  fi
}

check_uidmap() {
  local missing=() tool
  for tool in newuidmap newgidmap; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]} == 0)); then
    good "newuidmap and newgidmap are on PATH"
  else
    block "missing ${missing[*]}" "install the uidmap package (Fedora: sudo dnf install uidmap)"
  fi
}

check_podman() {
  if ! command -v podman >/dev/null 2>&1; then
    block "podman is not on PATH" "install Podman"
    return
  fi

  if user_exists "$service_user"; then
    check_podman_for "$service_user" ""
    return
  fi

  # The account does not exist yet, and install_account is about to create it.
  # Rootless Podman is a property of the host, not of one account: what is
  # per-account is the subordinate range, which check_account already owns. So
  # report what the host supports, measured on whoever ran this, and leave the
  # service account's own check to verify_service_podman, which runs after the
  # account and its range exist. Blocking here would stop the install before it
  # could create the account the block is about.
  local operator=${SUDO_USER:-$current_user}
  if [[ $operator == root ]]; then
    todo "rootless Podman for $service_user is checked during the install" \
      "no ordinary account is available to measure the host with; verify_service_podman runs once $service_user and its subordinate range exist"
    return
  fi
  check_podman_for "$operator" "$service_user is created with the same host support"
}

check_podman_for() {
  local target=$1 note=$2 rootless
  rootless=$(run_as_user "$target" podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)

  if [[ $rootless == true ]]; then
    good "rootless Podman works for $target${note:+; $note}"
  else
    block "Podman is not rootless for $target (reported '${rootless:-nothing}')" \
      "install and configure rootless Podman for $target"
  fi
}

check_install_commands() {
  [[ $mode == install ]] || return 0
  local missing=() tool
  for tool in useradd usermod install runuser systemctl chown; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]} == 0)); then
    good "account, install, and systemd commands are on PATH"
  else
    block "missing ${missing[*]}" "install the packages that provide them"
  fi
}

check_inputs() {
  local path
  valid_service_user "$service_user" ||
    block "service user '$service_user' is not a valid account name" "pass --service-user"
  valid_node_name "$node_name" ||
    block "node name '${node_name:-}' is not a lowercase DNS label" "pass --node-name, for example biot-node-1"
  [[ -n $server_host ]] || block "server host is not set" "pass --server-host"
  valid_fingerprint "$server_fingerprint" ||
    block "server fingerprint '${server_fingerprint:-}' is not 64 lowercase hex characters" \
      "pass --server-fingerprint from mix biot.certs server"
  valid_uuid "$registration_id" ||
    block "registration id '${registration_id:-}' is not a canonical UUID" \
      "pass --registration-id from the server's enrollment file"
  valid_port "$server_port" || block "server port '$server_port' is not a TCP port" "pass --server-port"
  if [[ -z $builder_image ]]; then
    block "builder image is not set and was not found in config/config.exs" \
      "pass --builder-image with the digest from config/config.exs"
  elif [[ $builder_image != *@sha256:* ]]; then
    block "builder image '$builder_image' is not pinned by digest" "pin the builder image by digest"
  else
    good "builder image is pinned: $builder_image"
  fi
  if [[ -z $binary_cache_urls || -z $binary_cache_keys ]]; then
    block "binary cache URLs or keys are empty" "pass --binary-cache-urls and --binary-cache-keys"
  else
    good "binary caches are $binary_cache_urls"
  fi
  for path in "$release_dir" "$data_root" "$certs_dir" "$env_file" "$unit_output"; do
    [[ $path == /* ]] || block "path '$path' is not absolute" "pass an absolute path"
  done
  canonical_path "$data_root" ||
    block "data root '$data_root' is not a canonical path" "remove trailing slashes or dot segments"
}

check_account() {
  if ! user_exists "$service_user"; then
    todo "the $service_user service account does not exist" \
      "useradd --system --create-home --shell /usr/sbin/nologin $service_user"
    todo "no /etc/subuid or /etc/subgid entry for $service_user" \
      "useradd --system --add-subids-for-system --create-home --shell /usr/sbin/nologin $service_user allocates one from /etc/login.defs"
    return
  fi

  good "service account $service_user exists"
  check_subid /etc/subuid "subordinate UID"
  check_subid /etc/subgid "subordinate GID"

  local uid_start gid_start
  uid_start=$(subid_start "$service_user" /etc/subuid)
  gid_start=$(subid_start "$service_user" /etc/subgid)
  if [[ -n $uid_start && -n $gid_start && $uid_start != "$gid_start" ]]; then
    block "/etc/subuid and /etc/subgid give $service_user different starts ($uid_start and $gid_start)" \
      "align them; the node maps UID and GID through one base"
  fi
}

check_subid() {
  local database=$1 label=$2 start count
  start=$(subid_start "$service_user" "$database")
  count=$(subid_count "$service_user" "$database")
  if [[ -z $start ]]; then
    block "no $label range for $service_user in $database" \
      "the account was created without one; remove it and let the installer recreate it ($recreate), or add an explicit range with usermod --add-subuids FIRST-LAST"
  elif ((count < uid_span)); then
    block "$database gives $service_user $count $label IDs starting at $start, but the node needs $uid_span" \
      "add more with usermod, or lower BIOT_NODE_UID_RANGE_LIMIT"
  else
    good "$database gives $service_user $count $label IDs starting at $start"
  fi
}

check_release() {
  if [[ -x $release_dir/bin/node ]]; then
    good "node release is installed at $release_dir"
  elif [[ -x $source_release/bin/node ]]; then
    good "node release to copy is at $source_release"
  else
    block "no node release at $release_dir or $source_release" \
      "build it with MIX_ENV=prod mix release node, or pass --source-release"
  fi
}

check_certs() {
  local file
  for file in "$node_ca" "$node_cert" "$node_key"; do
    if [[ -e $file ]]; then
      good "certificate material $file is present"
    else
      block "$file is missing" \
        "issue the node certificate on the machine that holds the authority (mix biot.certs node <dir> $node_name), then copy ca.pem and the node certificate and key into $certs_dir"
    fi
  done
}

run_preflight() {
  check_cgroup
  check_uidmap
  check_podman
  check_install_commands
  check_inputs
  check_account
  check_release
  check_certs
}

install_account() {
  if user_exists "$service_user"; then
    say "service account $service_user already exists"
    return
  fi
  # -F is what makes shadow-utils allocate a subordinate range for a system
  # account; without it useradd --system creates none. Allocation stays with
  # shadow-utils, which reads SUB_UID_MIN, SUB_UID_MAX, and SUB_UID_COUNT from
  # /etc/login.defs and will not hand out a range that overlaps another
  # account's. Choosing a start here would be this script guessing at a number
  # the host already owns.
  useradd --system --add-subids-for-system --create-home --shell /usr/sbin/nologin "$service_user"
  say "created service account $service_user with a subordinate range"
}

install_directories() {
  install -d -o "$service_user" -g "$service_user" -m 0750 "$release_dir" "$data_root" "$certs_dir"

  local env_dir unit_dir
  env_dir=$(dirname -- "$env_file")
  unit_dir=$(dirname -- "$unit_output")
  [[ -d $env_dir ]] || install -d -m 0750 "$env_dir"
  [[ -d $unit_dir ]] || install -d -m 0755 "$unit_dir"

  say "ensured $release_dir, $data_root, $certs_dir, and $env_dir"
}

install_cert_permissions() {
  # The node release reads these as the service user, so it has to be able to.
  chown "$service_user:$service_user" "$node_ca" "$node_cert" "$node_key"
  chmod 0644 "$node_ca" "$node_cert"
  chmod 0600 "$node_key"
  say "gave $service_user read access to the node certificate material"
}

read_subordinate_range() {
  local uid_count gid_start
  uid_base=$(subid_start "$service_user" /etc/subuid)
  gid_start=$(subid_start "$service_user" /etc/subgid)
  uid_count=$(subid_count "$service_user" /etc/subuid)
  [[ -n $uid_base && -n $uid_count ]] ||
    die "$service_user has no subordinate UID range in /etc/subuid; the account was created without one, so remove it and run this again (useradd --system --add-subids-for-system --create-home --shell /usr/sbin/nologin $service_user is what the installer does)"
  [[ $uid_base == "$gid_start" ]] ||
    die "/etc/subuid starts at $uid_base but /etc/subgid starts at $gid_start; the node needs one base"
  ((uid_count >= uid_span)) ||
    die "/etc/subuid gives $service_user $uid_count IDs; the node needs $uid_span"
  uid_limit=$((uid_base + uid_span))
  say "using subordinate range $uid_base:$uid_count (node limit $uid_limit)"
}

install_release() {
  if [[ -x $release_dir/bin/node ]]; then
    say "release already installed at $release_dir"
    return
  fi
  [[ -x $source_release/bin/node ]] || die "no node release at $source_release"
  say "copying $source_release to $release_dir"
  cp -R "$source_release/." "$release_dir/"
  chown -R "$service_user:$service_user" "$release_dir"
}

verify_service_podman() {
  local rootless
  if rootless=$(run_as_user "$service_user" podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null) &&
    [[ $rootless == true ]]; then
    say "rootless Podman works for $service_user"
  else
    die "rootless Podman failed for $service_user; fix it (see the node section of docs/deployment.md) before starting the node"
  fi
}

pull_builder_image() {
  say "pulling builder image $builder_image as $service_user"
  run_as_user "$service_user" podman pull "$builder_image"
}

write_env_file() {
  if [[ -e $env_file && $force_env -eq 0 ]]; then
    say "$env_file already exists; leaving it unchanged (--force-env regenerates it)"
    return
  fi

  local staging="${env_file}.new"
  {
    say "# Generated by deploy/install-node.sh. The node release reads this at boot."
    say "# Re-run with --force-env after changing the installer's flags to regenerate it."
    say "BIOT_NODE_REGISTRATION_ID=$registration_id"
    say "BIOT_SERVER_FINGERPRINT=$server_fingerprint"
    say "BIOT_SERVER_HOST=$server_host"
    say "BIOT_SERVER_PORT=$server_port"
    say "BIOT_NODE_DATA_ROOT=$data_root"
    say "BIOT_NODE_CERTFILE=$node_cert"
    say "BIOT_NODE_KEYFILE=$node_key"
    say "BIOT_NODE_CACERTFILE=$node_ca"
    say "BIOT_NODE_BUILDER_IMAGE=$builder_image"
    say "BIOT_NODE_BINARY_CACHE_URLS=$binary_cache_urls"
    say "BIOT_NODE_BINARY_CACHE_KEYS=$binary_cache_keys"
    say "BIOT_NODE_UID_RANGE_BASE=$uid_base"
    say "BIOT_NODE_UID_RANGE_COUNT=$uid_range_count"
    say "BIOT_NODE_UID_RANGE_LIMIT=$uid_limit"
  } >"$staging"
  chown "$service_user:$service_user" "$staging"
  chmod 0600 "$staging"
  mv -f -- "$staging" "$env_file"
  say "wrote $env_file (mode 0600, owned by $service_user)"
}

write_unit_file() {
  if [[ -e $unit_output && $force_unit -eq 0 ]]; then
    say "$unit_output already exists; leaving it unchanged (--force-unit regenerates it)"
    return
  fi

  {
    say "[Unit]"
    say "Description=Biot node"
    say "After=network-online.target"
    say "Wants=network-online.target"
    say ""
    say "[Service]"
    say "Type=simple"
    say "User=$service_user"
    say "Group=$service_user"
    say "WorkingDirectory=$release_dir"
    say "EnvironmentFile=$env_file"
    say "ExecStart=$release_dir/bin/node start"
    say "ExecStop=$release_dir/bin/node stop"
    # Rootless Podman needs its own cgroup subtree; without this a system service cannot manage the
    # worker's cgroups and every build fails.
    say "Delegate=yes"
    say "Restart=on-failure"
    say "RestartSec=5"
    say ""
    say "[Install]"
    say "WantedBy=multi-user.target"
  } >"$unit_output"
  chmod 0644 "$unit_output"
  say "wrote $unit_output for you to read and edit"
}

install_unit() {
  install -m 0644 -o root -g root "$unit_output" "$systemd_dir/$unit_name"
  systemctl daemon-reload
  say "installed $systemd_dir/$unit_name"
  if ((start_service)); then
    if systemctl enable --now "$unit_name"; then
      say "enabled and started $unit_name"
    else
      say "installed and enabled $unit_name, but it did not start; check: journalctl -u $unit_name -b"
    fi
  else
    systemctl enable "$unit_name"
    say "enabled $unit_name (not started; --no-start)"
  fi
}

report() {
  say ""
  say "node installed."
  say "  service user:   $service_user"
  say "  release:        $release_dir"
  say "  data root:      $data_root"
  say "  certificates:   $certs_dir"
  say "  environment:    $env_file"
  say "  unit file:      $unit_output"
  say "  installed unit: $systemd_dir/$unit_name"
  say "  UID range:      base $uid_base, $uid_range_count per biot, limit $uid_limit"
  say ""
  say "check it with:"
  say "  systemctl is-active $unit_name"
  say "  journalctl -u $unit_name -f"
}

run_install() {
  [[ $EUID -eq 0 ]] || die "installing writes host files and needs root; run with sudo"
  install_account
  install_directories
  install_cert_permissions
  read_subordinate_range
  install_release
  verify_service_podman
  pull_builder_image
  write_env_file
  write_unit_file
  install_unit
  report
}

say "Biot node install on $(uname -n)"
say ""
say "preflight:"
run_preflight

if ((${#blockers[@]} > 0)); then
  say ""
  say "preflight found ${#blockers[@]} problem(s) that must be fixed before installing."
  exit 1
fi

if ((${#todos[@]} > 0)); then
  say ""
  say "preflight found ${#todos[@]} step(s) the installer will perform."
fi

if [[ $mode == check ]]; then
  say ""
  say "check only: no changes made."
  exit 0
fi

say ""
run_install
