#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

docker image inspect biot-linux-host >/dev/null 2>&1 || docker build -t biot-linux-host docker/linux-host

log_file=$(mktemp)
trap 'rm -f "$log_file"' EXIT

if docker run --privileged --rm \
  -v "$PWD":/src:ro \
  -e MIX_ENV=test \
  biot-linux-host \
  -c 'set -e; cp -r /src "$HOME/work" && cd "$HOME/work" && rm -rf _build deps && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix test --max-cases 1 --seed 0' \
  >"$log_file" 2>&1; then
  status=0
else
  status=$?
fi

tail -60 "$log_file"
exit "$status"
