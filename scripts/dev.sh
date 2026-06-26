#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FE_DIR="$ROOT_DIR/../jinbocho-fe"

echo "==> Starting backend (Docker Compose)..."
docker compose -f "$ROOT_DIR/docker/docker-compose.community.local.yml" up --build -d

echo "==> Starting frontend (npm run dev)..."
cd "$FE_DIR"
npm run dev
