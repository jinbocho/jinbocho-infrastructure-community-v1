#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FE_DIR="$ROOT_DIR/../jinbocho-fe"
COMPOSE_FILE="$ROOT_DIR/docker/docker-compose.community.local.yml"

# The gateway trial repos (jinbocho-api-gateway-envoy-v2 / -apisix-v2) also
# bind host :8000 for transparent-replacement testing against this exact
# stack. Whichever one is still up from a previous session must go first, or
# `docker compose up` fails with "port is already allocated".
echo "==> Freeing port 8000 (any previous gateway container)..."
docker ps -q --filter "publish=8000" | xargs -r docker rm -f

# `docker rm -f` returns before Docker Desktop's proxy always finishes
# releasing the host socket -- without this wait, `up` right after can still
# hit "port is already allocated" in that brief window (seen in practice).
if command -v lsof >/dev/null 2>&1; then
  for _ in $(seq 1 10); do
    lsof -i :8000 -sTCP:LISTEN >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

echo "==> Cleaning up previous stack (including orphans)..."
docker compose -f "$COMPOSE_FILE" down --remove-orphans

if command -v lsof >/dev/null 2>&1 && lsof -i :8000 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "!! Port 8000 is still held outside Docker's own container tracking." >&2
  echo "!! This is a stale docker-proxy left behind by a 'docker rm -f' on a" >&2
  echo "!! live container (known Docker Desktop bug, not fixable from here)." >&2
  echo "!! Restart Docker Desktop, then re-run this script:" >&2
  echo "!!   osascript -e 'quit app \"Docker\"' && sleep 3 && open -a Docker" >&2
  exit 1
fi

echo "==> Starting backend (Docker Compose)..."
# The pre-checks above catch the common case, but Docker Desktop's port
# release can still lag past them and only surface once `up` actually tries
# to bind -- after the (cached, fast) build, seconds later. Retrying the
# real failing command is more robust than guessing a longer wait upfront.
attempt=1
until docker compose -f "$COMPOSE_FILE" up --build -d --remove-orphans; do
  if [[ $attempt -ge 3 ]]; then
    echo "!! 'docker compose up' still failing after $attempt attempts --" >&2
    echo "!! this is beyond the normal port-release race. Restart Docker" >&2
    echo "!! Desktop and re-run this script:" >&2
    echo "!!   osascript -e 'quit app \"Docker\"' && sleep 3 && open -a Docker" >&2
    exit 1
  fi
  echo "==> 'docker compose up' failed (attempt $attempt/3), likely the port-release race -- retrying in 3s..." >&2
  attempt=$((attempt + 1))
  sleep 3
done

echo "==> Starting frontend (npm run dev)..."
cd "$FE_DIR"
npm run dev
