#!/usr/bin/env bash
#
# Jinbocho — one-shot self-host installer for a fresh VPS (Hetzner, Scaleway,
# DigitalOcean, ... any Debian/Ubuntu server with a public IP). Installs
# Docker if needed, fetches the frontend source, generates secrets, writes
# every config file, builds the missing frontend image and brings the full
# stack (DBs + 3 backends + gateway + frontend + HTTPS reverse proxy) up in
# a single run.
#
# Usage (run from inside a checkout of jinbocho-infrastructure-v1):
#
#   ./scripts/setup-vps-community.sh --domain library.example.com --email you@example.com \
#       --google-books-key AIza... [--enable-firewall]
#
# Re-running is safe: existing secrets, env files and the Caddyfile are kept
# unless you delete them first. Pass --help for the full flag list.
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
DOMAIN=""
LETSENCRYPT_EMAIL=""
GOOGLE_BOOKS_KEY=""
SMTP_USER=""
SMTP_PASSWORD=""
EMAIL_FROM=""
GRAFANA_ENABLED=""
GRAFANA_OTLP_ENDPOINT="https://otlp-gateway-prod-eu-west-2.grafana.net/otlp"
GRAFANA_OTLP_INSTANCE_ID=""
GRAFANA_OTLP_API_TOKEN=""
FRONTEND_BASE_URL=""
FE_REPO="https://github.com/jinbocho/jinbocho-fe.git"
FE_BRANCH="master"
JINBOCHO_VERSION="latest"
ENABLE_FIREWALL="false"
SKIP_DOCKER_INSTALL="false"
NON_INTERACTIVE="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/setup-vps-community.sh [options]

Options:
  --domain <fqdn>            Public domain already pointed at this server (enables HTTPS)
  --email <email>            Let's Encrypt contact email (required with --domain)
  --google-books-key <key>   Google Books API key (catalog ISBN lookups)
  --smtp-user <email>        Gmail address used to send invite/reset emails (SMTP host/port are
                             set automatically; leave unset to keep the log/console fallback)
  --smtp-password <app-pw>   Gmail App Password for --smtp-user (https://myaccount.google.com/apppasswords)
  --email-from <email>       From address shown on outgoing emails (default: --smtp-user)
  --grafana-enabled true|false   Ship metrics/logs/traces to Grafana Cloud via the built-in
                                  Alloy collector, ADR-012 (default: asked interactively)
  --grafana-otlp-endpoint <url>   Grafana Cloud OTLP endpoint (Connections > OpenTelemetry)
  --grafana-otlp-instance-id <id> Grafana Cloud OTLP instance ID
  --grafana-otlp-api-token <tok>  Grafana Cloud OTLP API token
  --frontend-base-url <url>  Public frontend URL used in email links (default: derived from --domain/IP)
  --fe-repo <git-url>        Frontend repo to clone (default: jinbocho/jinbocho-fe)
  --fe-branch <branch>       Frontend branch to clone (default: main)
  --version <tag>            GHCR image tag for backend services (default: latest)
  --enable-firewall          Configure ufw (22/80/443) and enable it
  --skip-docker-install      Don't attempt to install Docker
  --non-interactive          Never prompt; use flags/defaults only
  -h, --help                 Show this help
USAGE
  exit 0
}

# ── arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) LETSENCRYPT_EMAIL="$2"; shift 2 ;;
    --google-books-key) GOOGLE_BOOKS_KEY="$2"; shift 2 ;;
    --smtp-user) SMTP_USER="$2"; shift 2 ;;
    --smtp-password) SMTP_PASSWORD="$2"; shift 2 ;;
    --email-from) EMAIL_FROM="$2"; shift 2 ;;
    --grafana-enabled) GRAFANA_ENABLED="$2"; shift 2 ;;
    --grafana-otlp-endpoint) GRAFANA_OTLP_ENDPOINT="$2"; shift 2 ;;
    --grafana-otlp-instance-id) GRAFANA_OTLP_INSTANCE_ID="$2"; shift 2 ;;
    --grafana-otlp-api-token) GRAFANA_OTLP_API_TOKEN="$2"; shift 2 ;;
    --frontend-base-url) FRONTEND_BASE_URL="$2"; shift 2 ;;
    --fe-repo) FE_REPO="$2"; shift 2 ;;
    --fe-branch) FE_BRANCH="$2"; shift 2 ;;
    --version) JINBOCHO_VERSION="$2"; shift 2 ;;
    --enable-firewall) ENABLE_FIREWALL="true"; shift ;;
    --skip-docker-install) SKIP_DOCKER_INSTALL="true"; shift ;;
    --non-interactive) NON_INTERACTIVE="true"; shift ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ -f "$SCRIPT_DIR/docker/docker-compose.all.yml" ]] || die "Run this from a checkout of jinbocho-infrastructure-v1 (docker-compose.all.yml not found)."

prompt() {
  local var_name="$1" question="$2" default="${3:-}"
  local current; current="$(eval "echo \${$var_name}")"
  [[ -n "$current" ]] && return 0
  [[ "$NON_INTERACTIVE" == "true" ]] && return 0
  local answer
  read -r -p "$question $( [[ -n "$default" ]] && echo "[$default] " )" answer || true
  answer="${answer:-$default}"
  printf -v "$var_name" '%s' "$answer"
}

echo
echo "  📚  Jinbocho — installazione self-host (Community)"
echo "  ───────────────────────────────────────────────────"
echo

prompt DOMAIN "Dominio pubblico già puntato a questo server (lascia vuoto per usare l'IP, niente HTTPS):" ""
if [[ -n "$DOMAIN" ]]; then
  prompt LETSENCRYPT_EMAIL "Email per i certificati Let's Encrypt:" ""
  [[ -n "$LETSENCRYPT_EMAIL" ]] || die "Hai indicato un dominio: serve anche --email per Let's Encrypt."
fi
prompt GOOGLE_BOOKS_KEY "Google Books API key (https://console.cloud.google.com/, lascia vuoto per usarla dopo):" ""

SERVER_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
if [[ -n "$DOMAIN" ]]; then
  PUBLIC_HOST="$DOMAIN"
  SCHEME="https"
else
  PUBLIC_HOST="$SERVER_IP"
  SCHEME="http"
fi

prompt SMTP_USER "Email Gmail per inviare le notifiche (invito utenti, reset password) — lascia vuoto per usare solo il fallback su log:" ""
if [[ -n "$SMTP_USER" ]]; then
  prompt SMTP_PASSWORD "App Password Gmail per $SMTP_USER (non la password normale — generala su https://myaccount.google.com/apppasswords):" ""
  prompt EMAIL_FROM "Indirizzo mostrato come mittente delle email:" "$SMTP_USER"
else
  warn "Nessuna email SMTP fornita: inviti e reset password finiranno solo nei log (docker logs jinbocho-auth)."
fi
prompt FRONTEND_BASE_URL "URL pubblico del frontend (usato nei link delle email):" "${SCHEME}://${PUBLIC_HOST}"

prompt GRAFANA_ENABLED "Inviare metriche/log/tracce a Grafana Cloud (ADR-012, richiede un account gratuito su grafana.com)? (y/n):" "n"
case "${GRAFANA_ENABLED,,}" in
  y|yes|true|1) GRAFANA_ENABLED="true" ;;
  *) GRAFANA_ENABLED="false" ;;
esac
if [[ "$GRAFANA_ENABLED" == "true" ]]; then
  prompt GRAFANA_OTLP_ENDPOINT "Endpoint OTLP (Grafana Cloud > Connections > Add new connection > OpenTelemetry):" "$GRAFANA_OTLP_ENDPOINT"
  prompt GRAFANA_OTLP_INSTANCE_ID "Instance ID (stessa pagina):" ""
  prompt GRAFANA_OTLP_API_TOKEN "API Token (stessa pagina):" ""
  [[ -n "$GRAFANA_OTLP_INSTANCE_ID" && -n "$GRAFANA_OTLP_API_TOKEN" ]] || die "Grafana abilitato: servono anche instance ID e API token (vedi --help)."
else
  log "Grafana Cloud non abilitato: puoi attivarlo in seguito riempiendo envs/alloy.env e i servizi con OTEL_ENABLED=true, poi rilanciando con --profile observability."
fi

# ── 1. Docker ───────────────────────────────────────────────────────────────
if [[ "$SKIP_DOCKER_INSTALL" != "true" ]] && ! command -v docker &>/dev/null; then
  log "Docker non trovato: installo con lo script ufficiale get.docker.com"
  curl -fsSL https://get.docker.com | sh
  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER" || true
    warn "Utente $SUDO_USER aggiunto al gruppo 'docker': serve un nuovo login per usare docker senza sudo."
  fi
else
  log "Docker già presente: $(docker --version 2>/dev/null || echo 'versione non rilevata')"
fi

docker compose version &>/dev/null || die "Il plugin 'docker compose' non è disponibile: aggiorna Docker (>=20.10 con compose v2)."

# ── 2. Firewall (opt-in: non blocchiamo SSH senza che l'operatore lo chieda) ──
if [[ "$ENABLE_FIREWALL" == "true" ]] && command -v ufw &>/dev/null; then
  log "Configuro ufw: apro 22 (SSH), 80 e 443"
  ufw allow OpenSSH || ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
else
  log "Salto la configurazione del firewall (passa --enable-firewall per attivarla)."
fi

# ── 3. Frontend source ──────────────────────────────────────────────────────
FE_DIR="$SCRIPT_DIR/../jinbocho-fe"
if [[ -d "$FE_DIR/.git" ]]; then
  log "jinbocho-fe già presente: aggiorno (git fetch + checkout $FE_BRANCH)"
  git -C "$FE_DIR" fetch origin "$FE_BRANCH"
  git -C "$FE_DIR" checkout "$FE_BRANCH"
  git -C "$FE_DIR" pull --ff-only origin "$FE_BRANCH"
else
  log "Clono il frontend ($FE_REPO@$FE_BRANCH) in $FE_DIR"
  git clone --branch "$FE_BRANCH" "$FE_REPO" "$FE_DIR"
fi

if [[ ! -f "$FE_DIR/Dockerfile" ]]; then
  log "jinbocho-fe non ha un Dockerfile proprio: copio il template (nginx + build Vite)"
  cp "$SCRIPT_DIR/docker/frontend/Dockerfile" "$FE_DIR/Dockerfile"
  cp "$SCRIPT_DIR/docker/frontend/nginx.conf" "$FE_DIR/nginx.conf"
else
  log "jinbocho-fe ha già un Dockerfile: lo lascio invariato."
fi

# ── 4. Secrets & env files ──────────────────────────────────────────────────
set_kv() { # set_kv <file> <key> <value>
  local file="$1" key="$2" value="$3"
  touch "$file"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

[[ -f .env ]] || { log "Creo .env"; cp .env.example .env; }
EXISTING_PG_PASS="$(grep -E '^POSTGRES_PASSWORD=' .env | cut -d= -f2- || true)"
if [[ -z "$EXISTING_PG_PASS" || "$EXISTING_PG_PASS" == "change_me_local_dev" ]]; then
  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
else
  POSTGRES_PASSWORD="$EXISTING_PG_PASS"
fi
set_kv .env POSTGRES_PASSWORD "$POSTGRES_PASSWORD"

EXISTING_JWT="$(grep -E '^JWT_SECRET_KEY=' .env | cut -d= -f2- || true)"
if [[ -z "$EXISTING_JWT" ]]; then
  JWT_SECRET="$(openssl rand -hex 32)"
else
  JWT_SECRET="$EXISTING_JWT"
fi
set_kv .env JWT_SECRET_KEY "$JWT_SECRET"
set_kv .env JINBOCHO_VERSION "$JINBOCHO_VERSION"
set_kv .env DOMAIN "${DOMAIN:-$SERVER_IP}"
set_kv .env VITE_API_BASE_URL "${SCHEME}://${PUBLIC_HOST}/api"

mkdir -p envs
copy_env() { [[ -f "envs/$1.env" ]] || cp "envs/$1.env.example" "envs/$1.env"; }
copy_env auth-service
copy_env catalog-service
copy_env api-gateway

for f in envs/auth-service.env envs/catalog-service.env envs/api-gateway.env; do
  sed -i "s|YOUR_POSTGRES_PASSWORD|${POSTGRES_PASSWORD}|g; s|YOUR_JWT_SECRET_KEY_HERE|${JWT_SECRET}|g; s|^DEBUG=true|DEBUG=false|" "$f"
done

# Reuses a previously-generated value across re-runs; only mints a new one if
# the key is missing or still holds the .env.example placeholder.
gen_or_reuse() { # gen_or_reuse <file> <key>
  local current
  current="$(grep -E "^${2}=" "$1" 2>/dev/null | cut -d= -f2- || true)"
  if [[ -z "$current" || "$current" == YOUR_*_HERE ]]; then
    openssl rand -hex 32
  else
    echo "$current"
  fi
}

# auth-service <-> catalog-service (loan reminder emails).
INTERNAL_SERVICE_TOKEN="$(gen_or_reuse envs/auth-service.env INTERNAL_SERVICE_TOKEN)"
set_kv envs/auth-service.env INTERNAL_SERVICE_TOKEN "$INTERNAL_SERVICE_TOKEN"
set_kv envs/catalog-service.env INTERNAL_SERVICE_TOKEN "$INTERNAL_SERVICE_TOKEN"
set_kv envs/catalog-service.env JINBOCHO_FEATURES "catalog,auth"

set_kv envs/api-gateway.env CORS_ORIGINS "[\"${SCHEME}://${PUBLIC_HOST}\"]"
set_kv envs/api-gateway.env JWT_ISSUER "jinbocho-auth"
set_kv envs/api-gateway.env JWT_AUDIENCE "jinbocho"

set_kv envs/auth-service.env FRONTEND_BASE_URL "$FRONTEND_BASE_URL"
if [[ -n "$SMTP_USER" ]]; then
  set_kv envs/auth-service.env SMTP_HOST "smtp.gmail.com"
  set_kv envs/auth-service.env SMTP_PORT "587"
  set_kv envs/auth-service.env SMTP_USER "$SMTP_USER"
  set_kv envs/auth-service.env SMTP_PASSWORD "$SMTP_PASSWORD"
  set_kv envs/auth-service.env EMAIL_FROM "${EMAIL_FROM:-$SMTP_USER}"
fi

if [[ -n "$GOOGLE_BOOKS_KEY" ]]; then
  sed -i "s|YOUR_GOOGLE_BOOKS_API_KEY_HERE|${GOOGLE_BOOKS_KEY}|" envs/catalog-service.env
else
  warn "Nessuna Google Books API key fornita: imposta GOOGLE_BOOKS_API_KEY in envs/catalog-service.env in seguito."
fi

if [[ "$GRAFANA_ENABLED" == "true" ]]; then
  [[ -f envs/alloy.env ]] || cp envs/alloy.env.example envs/alloy.env
  set_kv envs/alloy.env GRAFANA_CLOUD_OTLP_ENDPOINT "$GRAFANA_OTLP_ENDPOINT"
  set_kv envs/alloy.env GRAFANA_CLOUD_OTLP_INSTANCE_ID "$GRAFANA_OTLP_INSTANCE_ID"
  set_kv envs/alloy.env GRAFANA_CLOUD_OTLP_API_TOKEN "$GRAFANA_OTLP_API_TOKEN"
  for f in envs/auth-service.env envs/catalog-service.env envs/api-gateway.env; do
    set_kv "$f" OTEL_ENABLED "true"
  done
fi

# ── 5. Caddyfile (reverse proxy + HTTPS) ────────────────────────────────────
if [[ -f Caddyfile ]]; then
  log "Caddyfile esistente trovato: lo lascio invariato (rimuovilo manualmente per rigenerarlo)."
else
  log "Genero Caddyfile per ${SCHEME}://${PUBLIC_HOST}"
  {
    if [[ -n "$DOMAIN" ]]; then
      echo "{"
      echo "    email ${LETSENCRYPT_EMAIL}"
      echo "}"
      echo "${DOMAIN} {"
    else
      warn "Nessun dominio indicato: Caddy servirà in HTTP semplice su http://${SERVER_IP} (nessun certificato TLS)."
      echo "http://${SERVER_IP} {"
    fi
    cat <<'CADDY_BODY'
    encode gzip
    handle_path /api/* {
        reverse_proxy api-gateway:8000
    }
    handle {
        reverse_proxy frontend:80
    }
}
CADDY_BODY
  } > Caddyfile
fi

# ── 6. Build & start ─────────────────────────────────────────────────────────
# The compose file uses fixed container_name values, but older checkouts (or
# installs that predate pinning the Compose project name to "jinbocho") may
# have created containers with the same names under a different project.
# Docker refuses to create a same-named container regardless of project, so
# clear out any stale container that isn't already tracked by this project
# before starting — re-running the installer must stay safe.
for name in jinbocho-postgres-auth jinbocho-postgres-catalog \
            jinbocho-auth jinbocho-catalog jinbocho-api-gateway \
            jinbocho-frontend jinbocho-caddy; do
  project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
  if [[ -n "$project" && "$project" != "jinbocho" ]]; then
    warn "Rimuovo il container residuo '$name' (apparteneva al progetto Compose '$project')."
    docker rm -f "$name" &>/dev/null || true
  fi
done

COMPOSE_ARGS=(-f docker/docker-compose.all.yml --env-file .env)
[[ "$GRAFANA_ENABLED" == "true" ]] && COMPOSE_ARGS+=(--profile observability)

log "Pull immagini backend (GHCR) e build frontend da sorgente..."
docker compose "${COMPOSE_ARGS[@]}" pull --ignore-pull-failures
docker compose "${COMPOSE_ARGS[@]}" build frontend
docker compose "${COMPOSE_ARGS[@]}" up -d

# ── 7. Smoke test ─────────────────────────────────────────────────────────
log "Attendo che il gateway risponda..."
HEALTH_URL="${SCHEME}://${PUBLIC_HOST}/api/health"
ok="false"
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "$HEALTH_URL" 2>/dev/null; then ok="true"; break; fi
  sleep 2
done

echo
if [[ "$ok" == "true" ]]; then
  log "✅ Stack online."
else
  warn "Il gateway non ha ancora risposto su $HEALTH_URL — controlla 'docker compose ${COMPOSE_ARGS[@]} logs -f'."
fi

cat <<SUMMARY

  ───────────────────────────────────────────────────────────
  Jinbocho è in esecuzione (edizione: community)

  Frontend:        ${SCHEME}://${PUBLIC_HOST}
  API gateway:      ${SCHEME}://${PUBLIC_HOST}/api  (health: ${HEALTH_URL})
  Email (inviti/reset): $( [[ -n "$SMTP_USER" ]] && echo "via Gmail ($SMTP_USER)" || echo "fallback su log (docker logs jinbocho-auth) — imposta SMTP_USER/SMTP_PASSWORD in envs/auth-service.env per attivarla" )
  Metriche/log (Grafana Cloud): $( [[ "$GRAFANA_ENABLED" == "true" ]] && echo "abilitate — dashboard su grafana.com" || echo "disabilitate — riempi envs/alloy.env e rilancia con --profile observability per attivarle" )
  Secrets generati: .env, envs/*.env (non committati, vedi .gitignore)

  Prossimo passo: apri il frontend nel browser e registra la prima famiglia
  (diventa l'admin). Da lì in poi è tutto self-service per il cliente.

  Comandi utili:
    docker compose ${COMPOSE_ARGS[@]} logs -f
    docker compose ${COMPOSE_ARGS[@]} ps
    docker compose ${COMPOSE_ARGS[@]} down        # ferma tutto (i dati restano nei volumi)
  ───────────────────────────────────────────────────────────
SUMMARY
