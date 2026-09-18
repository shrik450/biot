#!/usr/bin/env bash
set -euo pipefail

repo_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
keep_run_directory=0

if [[ "${1:-}" == "--keep" ]]; then
  keep_run_directory=1
  shift
fi

if (( $# > 0 )); then
  printf 'usage: %s [--keep]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

mkdir -p "$repo_directory/.work"
run_directory=$(mktemp -d "$repo_directory/.work/node-host.XXXXXX")
cache_directory=${XDG_CACHE_HOME:-$HOME/.cache}
mkdir -p "$cache_directory"
data_directory=$(mktemp -d "$cache_directory/biot-dev.XXXXXX")
server_pid=
node_pid=
stop_requested=0

stop_process_group() {
  local pid=$1

  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null

    for _attempt in {1..100}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done

    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    fi
  fi

  wait "$pid" 2>/dev/null
}

cleanup_containers() {
  local module_file="$data_directory/podman.conf"
  [[ -f "$module_file" ]] || return 0

  local container_id mounts
  while read -r container_id; do
    [[ -n "$container_id" ]] || continue
    mounts=$(podman inspect "$container_id" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
    case "$mounts" in
      *"$data_directory"*)
        podman --module "$module_file" rm -f "$container_id" >/dev/null 2>&1 || podman rm -f "$container_id" >/dev/null 2>&1
        ;;
    esac
  done < <(podman --module "$module_file" ps -aq 2>/dev/null)
}

cleanup_networks() {
  local module_file="$data_directory/podman.conf"
  local allocations_directory="$data_directory/biots"
  [[ -f "$module_file" && -d "$allocations_directory" ]] || return 0

  local biot_id
  while read -r biot_id; do
    [[ -n "$biot_id" ]] || continue
    podman --module "$module_file" network rm "biot-network-$biot_id" >/dev/null 2>&1 || true
  done < <(find "$allocations_directory" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
}

cleanup() {
  status=$?
  trap - EXIT INT TERM
  set +e

  if [[ -n "$node_pid" ]]; then
    stop_process_group "$node_pid"
  fi

  if [[ -n "$server_pid" ]]; then
    stop_process_group "$server_pid"
  fi

  cleanup_containers
  cleanup_networks

  if [[ "$keep_run_directory" -eq 0 && ("$stop_requested" -eq 1 || "$status" -eq 0) ]]; then
    podman unshare rm -rf -- "$run_directory" "$data_directory"
  else
    printf 'run directory preserved: %s\n' "$run_directory" >&2
    printf 'data root preserved: %s\n' "$data_directory" >&2
  fi

  exit "$status"
}

trap cleanup EXIT
trap 'stop_requested=1; exit 0' INT TERM

(
  cd "$repo_directory"
  BIOT_RUN_DIRECTORY="$run_directory" BIOT_DATA_DIRECTORY="$data_directory" MIX_ENV=dev mise exec -- mix run --no-start dev/local_bootstrap.exs
) >"$run_directory/bootstrap.log" 2>&1
source "$run_directory/environment"

setsid --wait bash -c 'cd "$1"; shift; exec "$@"' _ "$repo_directory" \
  mise exec -- mix run --no-start dev/stack.exs >"$run_directory/server.log" 2>&1 &
server_pid=$!

wait_for_file() {
  local path=$1
  local deadline=$((SECONDS + 60))

  while ((SECONDS < deadline)); do
    if [[ -f "$path" ]]; then
      return 0
    fi

    if ! kill -0 "$server_pid" 2>/dev/null; then
      printf 'server exited before writing %s\n' "$path" >&2
      return 1
    fi

    sleep 0.1
  done

  printf 'server did not write %s\n' "$path" >&2
  return 1
}

wait_for_file "$BIOT_DEV_READY_FILE.server"

setsid --wait bash -c 'cd "$1"; shift; exec "$@"' _ "$repo_directory" \
  env MIX_ENV=dev mise exec -- mix run --no-start dev/node.exs >"$run_directory/node.log" 2>&1 &
node_pid=$!

ready_timeout=1230

ready_deadline=$((SECONDS + ready_timeout))
while [[ ! -f "$BIOT_DEV_READY_FILE.node" ]]; do
  if ! kill -0 "$node_pid" 2>/dev/null; then
    printf 'node exited before the control link became ready\n' >&2
    keep_run_directory=1
    exit 1
  fi

  if ((SECONDS >= ready_deadline)); then
    printf 'node control link did not become ready\n' >&2
    keep_run_directory=1
    exit 1
  fi

  sleep 0.1
done

printf 'server and node are ready\n'
printf 'server log: %s\nnode log: %s\nrun directory: %s\ndata root: %s\n' \
  "$run_directory/server.log" "$run_directory/node.log" "$run_directory" "$data_directory"
printf 'HTTP: http://localhost:%s\n' "$PORT"
printf 'node: %s\n' "$BIOT_DEV_NODE_ID"
printf 'Stop with Ctrl-C.\n'

wait "$node_pid"
