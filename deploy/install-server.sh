#!/usr/bin/env bash
#
# install-server.sh — bring up a Biot server host with one idempotent command.
#
# It performs the systemd "## Server" host setup from docs/deployment.md: it checks the host first,
# creates the service account and its paths, generates the SSH host key, copies the server release,
# gives the service account read access to the control-link certificates it was given, writes the
# release environment, and installs and starts the systemd unit. Run it again and it only fills in
# what is missing.
#
# The two pieces of material it does not create are the operator's: the control-link certificates
# (issuing them needs the authority's private key, which stays on the operator's machine) and the
# node enrollment file (mix biot.enroll writes it). This script places and permission them.
#
# Run it as root on the server host:
#
#   sudo deploy/install-server.sh \
#     --control-host biot.example.com --publication-domain preview.example.com \
#     --oidc-issuer https://id.example.com --oidc-client-id biot \
#     --oidc-client-secret-file /root/biot-oidc-secret
#
# Give it --check to run only the preflight and stop; it makes no changes in that mode.
#
# The OIDC client secret is read from --oidc-client-secret-file or BIOT_OIDC_CLIENT_SECRET, never
# from the command line, so it does not reach the process list or the shell history.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "$script_dir/.." && pwd)

service_user=biot
release_dir=/opt/biot/server
source_release="$repo_dir/_build/prod/rel/server"
data_dir=/var/lib/biot
config_dir=/etc/biot
certs_dir=/etc/biot/certs
env_file=/etc/biot/server.env
unit_output=/etc/biot/biot-server.service
unit_name=biot-server.service
systemd_dir=/etc/systemd/system
ssh_host_key=/etc/biot/ssh-host-key
database=
registrations=
control_host=
publication_domain=
oidc_issuer=
oidc_client_id=
oidc_client_secret_file=
oidc_client_secret=
http_port=4000
control_port=4443
ssh_port=2222
ssh_advertised_host=
mode=install
start_service=1
force_env=0
force_unit=0

usage() {
  cat <<'EOF'
usage: install-server.sh [options]

Runs the Biot server host setup on this machine. An install needs --control-host,
--publication-domain, --oidc-issuer, --oidc-client-id, and the OIDC client secret.

Options:
  --check                       Run the preflight checks only and stop. Makes no changes.
  --no-start                    Install and enable the unit but do not start it.
  --service-user NAME           Service account (default: biot).
  --release-dir DIR             Where the server runs from (default: /opt/biot/server).
  --source-release DIR          Built release to copy (default: <repo>/_build/prod/rel/server).
  --data-dir DIR                Directory holding the database (default: /var/lib/biot).
  --database FILE               SQLite database path (default: <data-dir>/server.sqlite3).
  --config-dir DIR              Directory for configuration and key material (default: /etc/biot).
  --certs-dir DIR               Control-link certificates (default: /etc/biot/certs).
  --env-file FILE               Release environment file (default: /etc/biot/server.env).
  --unit-output FILE            Where to write the unit for the operator to read and edit
                                (default: /etc/biot/biot-server.service).
  --ssh-host-key FILE           SSH host key (default: /etc/biot/ssh-host-key).
  --registrations FILE          Node enrollment file the server imports; optional, and the server
                                accepts no node without it.
  --control-host HOST           PHX_HOST: the control hostname (a lowercase DNS name).
  --publication-domain DOMAIN   BIOT_SERVER_PUBLICATION_DOMAIN: the preview suffix.
  --oidc-issuer URL             The provider's HTTPS issuer URL.
  --oidc-client-id ID           The server's OIDC client id.
  --oidc-client-secret-file FILE  File holding the OIDC client secret; the environment variable
                                BIOT_OIDC_CLIENT_SECRET is the fallback.
  --http-port PORT              HTTP listener (default: 4000).
  --control-port PORT           Node-control listener (default: 4443).
  --ssh-port PORT               SSH listener (default: 2222).
  --ssh-advertised-host HOST    Host printed for SSH clients (default: the control host).
  --force-env                   Regenerate --env-file even if it exists.
  --force-unit                  Regenerate --unit-output even if it exists.
  -h, --help                    Show this help.

The control-link certificates and the node enrollment file are the operator's to create: issue the
certificates where the authority lives with mix biot.certs, write the enrollment file with
mix biot.enroll, and put both here before installing.
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
  printf 'install-server: %s\n' "$*" >&2
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
    --data-dir) need_value "$@"; data_dir=$2; shift 2 ;;
    --database) need_value "$@"; database=$2; shift 2 ;;
    --config-dir) need_value "$@"; config_dir=$2; shift 2 ;;
    --certs-dir) need_value "$@"; certs_dir=$2; shift 2 ;;
    --env-file) need_value "$@"; env_file=$2; shift 2 ;;
    --unit-output) need_value "$@"; unit_output=$2; shift 2 ;;
    --ssh-host-key) need_value "$@"; ssh_host_key=$2; shift 2 ;;
    --registrations) need_value "$@"; registrations=$2; shift 2 ;;
    --control-host) need_value "$@"; control_host=$2; shift 2 ;;
    --publication-domain) need_value "$@"; publication_domain=$2; shift 2 ;;
    --oidc-issuer) need_value "$@"; oidc_issuer=$2; shift 2 ;;
    --oidc-client-id) need_value "$@"; oidc_client_id=$2; shift 2 ;;
    --oidc-client-secret-file) need_value "$@"; oidc_client_secret_file=$2; shift 2 ;;
    --http-port) need_value "$@"; http_port=$2; shift 2 ;;
    --control-port) need_value "$@"; control_port=$2; shift 2 ;;
    --ssh-port) need_value "$@"; ssh_port=$2; shift 2 ;;
    --ssh-advertised-host) need_value "$@"; ssh_advertised_host=$2; shift 2 ;;
    --force-env) force_env=1; shift ;;
    --force-unit) force_unit=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

: "${database:=$data_dir/server.sqlite3}"
: "${ssh_advertised_host:=$control_host}"

server_cert="$certs_dir/server-cert.pem"
server_key="$certs_dir/server-key.pem"
ca_cert="$certs_dir/ca.pem"

user_exists() { id -u "$1" >/dev/null 2>&1; }

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
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }
valid_domain() {
  [[ ${#1} -le 253 && $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]
}
valid_issuer() {
  local rest
  [[ $1 == https://* ]] || return 1
  rest=${1#https://}
  rest=${rest%%/*}
  [[ -n $rest ]]
}
within_domain() { [[ $1 == "$2" || $1 == *".$2" ]]; }

read_env_value() {
  [[ -f $1 ]] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '\n'
  else
    head -c 48 /dev/urandom | base64 | tr -d '\n'
  fi
}

blockers=()
todos=()

check_commands() {
  [[ $mode == install ]] || return 0
  local missing=() tool
  for tool in useradd install systemctl ssh-keygen chown; do
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
  valid_domain "$control_host" ||
    block "control host '${control_host:-}' is not a lowercase DNS name" "pass --control-host"
  valid_domain "$publication_domain" ||
    block "publication domain '${publication_domain:-}' is not a lowercase DNS name" "pass --publication-domain"
  if valid_domain "$control_host" && valid_domain "$publication_domain" &&
    within_domain "$control_host" "$publication_domain"; then
    block "control host $control_host is the publication domain or a name under it" \
      "choose a control host outside $publication_domain"
  fi
  valid_issuer "$oidc_issuer" ||
    block "OIDC issuer '${oidc_issuer:-}' is not an HTTPS URL" "pass --oidc-issuer"
  [[ -n $oidc_client_id ]] || block "OIDC client id is empty" "pass --oidc-client-id"
  valid_port "$http_port" || block "HTTP port '$http_port' is not a TCP port" "pass --http-port"
  valid_port "$control_port" || block "control port '$control_port' is not a TCP port" "pass --control-port"
  valid_port "$ssh_port" || block "SSH port '$ssh_port' is not a TCP port" "pass --ssh-port"
  [[ -n $ssh_advertised_host ]] ||
    block "SSH advertised host is empty" "pass --ssh-advertised-host or --control-host"
  for path in "$release_dir" "$data_dir" "$config_dir" "$certs_dir" "$env_file" "$unit_output" "$ssh_host_key" "$database"; do
    [[ $path == /* ]] || block "path '$path' is not absolute" "pass an absolute path"
  done
  if valid_domain "$control_host" && valid_domain "$publication_domain" && valid_issuer "$oidc_issuer"; then
    good "control host $control_host, publication domain $publication_domain, issuer $oidc_issuer"
  fi
  if valid_port "$http_port" && valid_port "$control_port" && valid_port "$ssh_port"; then
    good "listeners: HTTP $http_port, control $control_port, SSH $ssh_port"
  fi
}

check_secret() {
  if [[ -n $oidc_client_secret_file ]]; then
    if [[ -r $oidc_client_secret_file ]]; then
      oidc_client_secret=$(tr -d '\r\n' <"$oidc_client_secret_file")
      if [[ -z $oidc_client_secret ]]; then
        block "the OIDC client secret file $oidc_client_secret_file is empty" "put the client secret in it"
      else
        good "OIDC client secret read from $oidc_client_secret_file"
      fi
    else
      block "cannot read the OIDC client secret file $oidc_client_secret_file" "check the path and its permissions"
    fi
  elif [[ -n ${BIOT_OIDC_CLIENT_SECRET:-} ]]; then
    oidc_client_secret=$BIOT_OIDC_CLIENT_SECRET
    good "OIDC client secret read from BIOT_OIDC_CLIENT_SECRET"
  else
    block "no OIDC client secret" \
      "pass --oidc-client-secret-file, or set BIOT_OIDC_CLIENT_SECRET"
  fi
}

check_account() {
  if user_exists "$service_user"; then
    good "service account $service_user exists"
  else
    todo "the $service_user service account does not exist" \
      "useradd --system --create-home --shell /usr/sbin/nologin $service_user"
  fi
}

check_release() {
  if [[ -x $release_dir/bin/server ]]; then
    good "server release is installed at $release_dir"
  elif [[ -x $source_release/bin/server ]]; then
    good "server release to copy is at $source_release"
  else
    block "no server release at $release_dir or $source_release" \
      "build it with MIX_ENV=prod mix release server, or pass --source-release"
  fi
}

check_certs() {
  local file
  for file in "$ca_cert" "$server_cert" "$server_key"; do
    if [[ -e $file ]]; then
      good "control-link certificate $file is present"
    else
      block "$file is missing" \
        "issue the server certificate where the authority lives (mix biot.certs server <dir>), then copy ca.pem, server-cert.pem, and server-key.pem into $certs_dir"
    fi
  done
}

check_ssh_host_key() {
  if [[ -e $ssh_host_key ]]; then
    good "SSH host key $ssh_host_key is present"
  else
    todo "no SSH host key at $ssh_host_key" "the installer will generate one with ssh-keygen"
  fi
}

check_registrations() {
  if [[ -z $registrations ]]; then
    todo "no node enrollment file is set" \
      "write one with mix biot.enroll and pass --registrations; without it the server accepts no node"
    return
  fi
  if [[ -r $registrations ]]; then
    good "node enrollment file $registrations is readable"
  else
    block "node enrollment file $registrations is not readable" "check the path and its permissions"
  fi
}

run_preflight() {
  check_commands
  check_inputs
  check_secret
  check_account
  check_release
  check_certs
  check_ssh_host_key
  check_registrations
}

install_account() {
  if user_exists "$service_user"; then
    say "service account $service_user already exists"
    return
  fi
  useradd --system --create-home --shell /usr/sbin/nologin "$service_user"
  say "created service account $service_user"
}

install_directories() {
  install -d -o "$service_user" -g "$service_user" -m 0750 "$release_dir" "$data_dir" "$certs_dir"

  local env_dir unit_dir
  env_dir=$(dirname -- "$env_file")
  unit_dir=$(dirname -- "$unit_output")
  [[ -d $env_dir ]] || install -d -m 0750 "$env_dir"
  [[ -d $unit_dir ]] || install -d -m 0755 "$unit_dir"

  say "ensured $release_dir, $data_dir, $certs_dir, and $env_dir"
}

install_cert_permissions() {
  chown "$service_user:$service_user" "$ca_cert" "$server_cert" "$server_key"
  chmod 0644 "$ca_cert" "$server_cert"
  chmod 0600 "$server_key"
  say "gave $service_user read access to the control-link certificates"
}

generate_ssh_host_key() {
  if [[ -e $ssh_host_key ]]; then
    say "SSH host key already exists at $ssh_host_key"
  else
    ssh-keygen -q -t ed25519 -N "" -f "$ssh_host_key"
    say "generated SSH host key $ssh_host_key"
  fi
  chown "$service_user:$service_user" "$ssh_host_key"
  chmod 0600 "$ssh_host_key"
  if [[ -e "$ssh_host_key.pub" ]]; then
    chown "$service_user:$service_user" "$ssh_host_key.pub"
    chmod 0644 "$ssh_host_key.pub"
  fi
}

install_release() {
  if [[ -x $release_dir/bin/server ]]; then
    say "release already installed at $release_dir"
    return
  fi
  [[ -x $source_release/bin/server ]] || die "no server release at $source_release"
  say "copying $source_release to $release_dir"
  cp -R "$source_release/." "$release_dir/"
  chown -R "$service_user:$service_user" "$release_dir"
}

install_registrations() {
  [[ -n $registrations ]] || return 0
  chown "$service_user:$service_user" "$registrations"
  chmod 0640 "$registrations"
  say "gave $service_user read access to the node enrollment file"
}

write_env_file() {
  local existing_secret
  existing_secret=$(read_env_value "$env_file" SECRET_KEY_BASE)

  if [[ -e $env_file && $force_env -eq 0 ]]; then
    say "$env_file already exists; leaving it unchanged (--force-env regenerates it)"
    return
  fi

  local secret_key_base
  if [[ -n $existing_secret ]]; then
    secret_key_base=$existing_secret
  else
    secret_key_base=$(generate_secret)
  fi

  local staging="${env_file}.new"
  {
    say "# Generated by deploy/install-server.sh. The server release reads this at boot."
    say "# Re-run with --force-env after changing the installer's flags to regenerate it."
    say "PHX_HOST=$control_host"
    say "BIOT_SERVER_PUBLICATION_DOMAIN=$publication_domain"
    say "SECRET_KEY_BASE=$secret_key_base"
    say "BIOT_OIDC_ISSUER=$oidc_issuer"
    say "BIOT_OIDC_CLIENT_ID=$oidc_client_id"
    say "BIOT_OIDC_CLIENT_SECRET=$oidc_client_secret"
    say "BIOT_SERVER_DATABASE=$database"
    say "BIOT_SSH_ADVERTISED_HOST=$ssh_advertised_host"
    say "BIOT_SSH_PORT=$ssh_port"
    say "BIOT_SSH_HOST_KEY_FILE=$ssh_host_key"
    say "BIOT_CONTROL_CERTFILE=$server_cert"
    say "BIOT_CONTROL_KEYFILE=$server_key"
    say "BIOT_CONTROL_CACERTFILE=$ca_cert"
    say "PORT=$http_port"
    say "BIOT_CONTROL_PORT=$control_port"
    if [[ -n $registrations ]]; then
      say "BIOT_NODE_REGISTRATIONS=$registrations"
    fi
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

  local needs_capability=0 port
  for port in "$http_port" "$control_port" "$ssh_port"; do
    ((10#$port < 1024)) && needs_capability=1
  done

  {
    say "[Unit]"
    say "Description=Biot server"
    say "After=network-online.target"
    say "Wants=network-online.target"
    say ""
    say "[Service]"
    say "Type=simple"
    say "User=$service_user"
    say "Group=$service_user"
    say "WorkingDirectory=$release_dir"
    say "EnvironmentFile=$env_file"
    say "ExecStart=$release_dir/bin/server start"
    say "ExecStop=$release_dir/bin/server stop"
    if ((needs_capability)); then
      # A listener below 1024 needs this; the service account owns no other privilege.
      say "AmbientCapabilities=CAP_NET_BIND_SERVICE"
      say "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
    fi
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
  local fingerprint
  fingerprint=$(ssh-keygen -lf "$ssh_host_key" 2>/dev/null | awk '{print $2}')

  say ""
  say "server installed."
  say "  service user:    $service_user"
  say "  release:         $release_dir"
  say "  data directory:  $data_dir"
  say "  database:        $database"
  say "  certificates:    $certs_dir"
  say "  SSH host key:    $ssh_host_key (${fingerprint:-unknown})"
  say "  environment:     $env_file"
  say "  unit file:       $unit_output"
  say "  installed unit:  $systemd_dir/$unit_name"
  if [[ -n $registrations ]]; then
    say "  node enrollment: $registrations"
  else
    say "  node enrollment: none; the server accepts no node until you set one"
  fi
  say ""
  say "check it with:"
  say "  systemctl is-active $unit_name"
  say "  journalctl -u $unit_name -f"
  say "  curl -sS http://127.0.0.1:$http_port/health"
}

run_install() {
  [[ $EUID -eq 0 ]] || die "installing writes host files and needs root; run with sudo"
  install_account
  install_directories
  install_cert_permissions
  generate_ssh_host_key
  install_release
  install_registrations
  write_env_file
  write_unit_file
  install_unit
  report
}

say "Biot server install on $(uname -n)"
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
