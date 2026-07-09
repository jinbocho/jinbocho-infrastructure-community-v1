#!/usr/bin/env bash
#
# Reads the currently-deployed config (.env, envs/*.env, Caddyfile) on this
# VPS and generates a fully-flagged, idempotent setup-vps-community.sh
# invocation — every value explicit, nothing left to interactive
# prompts/defaults. Re-running the generated command later (e.g. to flip on
# the Grafana Cloud observability profile) can't silently reset the
# Caddyfile/domain to plain HTTP or blank out an already-configured value,
# since setup-vps-community.sh only applies its interactive defaults when a
# flag is left empty AND not running --non-interactive.
#
# Usage (run from inside a checkout of jinbocho-infrastructure-v1, on the VPS):
#
#   ./scripts/build-reinstall-cmd.sh
#
# Output: ~/jinbocho-reinstall.sh (chmod 700 — contains secrets in clear text,
# never committed, delete it once you're done reusing it).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$SCRIPT_DIR/docker/docker-compose.all.yml" ]] || die "Run this from a checkout of jinbocho-infrastructure-v1 (docker-compose.all.yml not found)."

get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }

DOMAIN="$(get .env DOMAIN)"
JINBOCHO_VERSION="$(get .env JINBOCHO_VERSION)"
LETSENCRYPT_EMAIL="$(sed -n 's/^[[:space:]]*email[[:space:]]*//p' Caddyfile 2>/dev/null | head -1 || true)"
GOOGLE_BOOKS_KEY="$(get envs/catalog-service.env GOOGLE_BOOKS_API_KEY)"
FRONTEND_BASE_URL="$(get envs/auth-service.env FRONTEND_BASE_URL)"
SMTP_USER="$(get envs/auth-service.env SMTP_USER)"
SMTP_PASSWORD="$(get envs/auth-service.env SMTP_PASSWORD)"
EMAIL_FROM="$(get envs/auth-service.env EMAIL_FROM)"

OUT="$HOME/jinbocho-reinstall.sh"

{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo "cd \"$SCRIPT_DIR\""
  echo './scripts/setup-vps-community.sh \'
  echo "  --non-interactive \\"
  [[ -n "$DOMAIN" ]]            && echo "  --domain '$DOMAIN' \\"
  [[ -n "$LETSENCRYPT_EMAIL" ]] && echo "  --email '$LETSENCRYPT_EMAIL' \\"
  [[ -n "$GOOGLE_BOOKS_KEY" && "$GOOGLE_BOOKS_KEY" != "YOUR_GOOGLE_BOOKS_API_KEY_HERE" ]] && echo "  --google-books-key '$GOOGLE_BOOKS_KEY' \\"
  [[ -n "$SMTP_USER" ]]         && echo "  --smtp-user '$SMTP_USER' \\"
  [[ -n "$SMTP_PASSWORD" ]]     && echo "  --smtp-password '$SMTP_PASSWORD' \\"
  [[ -n "$EMAIL_FROM" ]]        && echo "  --email-from '$EMAIL_FROM' \\"
  [[ -n "$FRONTEND_BASE_URL" ]] && echo "  --frontend-base-url '$FRONTEND_BASE_URL' \\"
  [[ -n "$JINBOCHO_VERSION" ]]  && echo "  --version '$JINBOCHO_VERSION' \\"
  echo "  --grafana-enabled true \\"
  echo "  --grafana-otlp-endpoint 'INSERISCI_ENDPOINT_GRAFANA' \\"
  echo "  --grafana-otlp-instance-id 'INSERISCI_INSTANCE_ID' \\"
  echo "  --grafana-otlp-api-token 'INSERISCI_API_TOKEN'"
} > "$OUT"

chmod 700 "$OUT"
log "Generato: $OUT"
log "Apri e completa i placeholder INSERISCI_* (o rimuovi le righe --grafana-* se non vuoi abilitarlo), poi: bash $OUT"
