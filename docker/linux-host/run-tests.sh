#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

docker image inspect biot-linux-host >/dev/null 2>&1 || docker build -t biot-linux-host docker/linux-host

log_file=$(mktemp)
source_archive=$(mktemp)
trap 'rm -f "$log_file" "$source_archive"' EXIT

# Copy only source inputs. Test-created private keys and crash dumps can be unreadable through a
# rootless container mount, and none of the ignored build output belongs in the test workspace.
git ls-files --cached --others --exclude-standard -z \
  | while IFS= read -r -d '' path; do
      case "$path" in
        .work/*) ;;
        *) [[ -e "$path" || -L "$path" ]] && printf '%s\0' "$path" ;;
      esac
    done \
  | tar --null --files-from=- --create --file="$source_archive"
chmod 0644 "$source_archive"

if docker run --privileged --rm \
  -v "$source_archive":/source.tar:ro \
  -e MIX_ENV=test \
  biot-linux-host \
  -c 'set -e; mkdir "$HOME/work" && tar -xf /source.tar -C "$HOME/work" && cd "$HOME/work" && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix setup >/dev/null && mix test --max-cases 1 --seed 0' \
  >"$log_file" 2>&1; then
  status=0
else
  status=$?
fi

tail -60 "$log_file"
exit "$status"
