#!/usr/bin/env bash
#
# Jinbocho — backup del database PostgreSQL self-hosted su Docker.
# Pensato per essere lanciato da cron su una VPS (community o all-in-one).
#
# ADR-018: dal passaggio a un unico database "jinbocho" (schemi auth/
# catalog/ai) questo script esegue UN SOLO pg_dump dell'intero database in
# formato custom (-Fc), non più un dump separato per servizio — un dump
# unico è l'intero punto di ADR-018 ("one pg_dump of one database is a
# point-in-time-consistent snapshot"; tre dump separati, anche se lanciati
# in sequenza da questo stesso script, non lo sarebbero). Il formato custom
# permette comunque il restore selettivo di un solo schema con `pg_restore
# -n <schema>`, vedi sotto.
#
# Uso manuale (dalla root del checkout o da qualsiasi directory):
#
#   ./scripts/backup-db.sh
#   ./scripts/backup-db.sh --backup-dir /var/backups/jinbocho --retention-days 14
#
# Cron — ogni notte alle 03:00, log in /var/log/jinbocho-backup.log:
#
#   0 3 * * * /opt/jinbocho-infrastructure-v1/scripts/backup-db.sh >> /var/log/jinbocho-backup.log 2>&1
#
# Restore completo di un backup:
#
#   gunzip -c /var/backups/jinbocho/jinbocho_20260618_0300.dump.gz \
#     | docker exec -i jinbocho-postgres pg_restore -U postgres -d jinbocho --clean --if-exists
#
# Restore di un solo schema (es. solo "catalog", lasciando auth/ai intatti):
#
#   gunzip -c /var/backups/jinbocho/jinbocho_20260618_0300.dump.gz \
#     | docker exec -i jinbocho-postgres pg_restore -U postgres -d jinbocho -n catalog --clean --if-exists
#
# Copia off-site opzionale su GitHub Releases: imposta --github-repo (o la
# env GITHUB_BACKUP_REPO) con una repo privata dedicata ai backup
# (es. jinbocho/jinbocho-db-backups). Richiede la GitHub CLI (`gh`) già
# autenticata sulla VPS (`gh auth login`, o env GH_TOKEN/GITHUB_TOKEN con
# permesso "contents: write" su quella repo). Ogni run crea una release
# taggata "backup-<timestamp>" con il dump come asset; le release più
# vecchie di --retention-days vengono cancellate con `gh release delete`.
#
# Pass --help per i flag disponibili.
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
BACKUP_DIR="/var/backups/jinbocho"
RETENTION_DAYS="14"
CONTAINER_NAME="jinbocho-postgres"
GITHUB_REPO="${GITHUB_BACKUP_REPO:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/backup-db.sh [options]

Options:
  --backup-dir <path>     Directory dove salvare i dump (default: /var/backups/jinbocho)
  --retention-days <n>    Giorni di retention, locale e su GitHub (default: 14, 0 = nessuna pulizia)
  --github-repo <owner/repo>   Repo GitHub (privata) dove pubblicare i dump come Release asset.
                                Default: env GITHUB_BACKUP_REPO. Vuoto = nessun upload off-site.
  -h, --help              Mostra questo help
USAGE
  exit 0
}

# ── arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    --retention-days) RETENTION_DAYS="$2"; shift 2 ;;
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "Argomento non riconosciuto: $1 (vedi --help)" ;;
  esac
done

command -v docker &>/dev/null || die "Docker non trovato nel PATH."
if [[ -n "$GITHUB_REPO" ]]; then
  if ! command -v gh &>/dev/null; then
    warn "GitHub CLI ('gh') non trovata nel PATH: salto la copia off-site, procedo solo con il backup locale."
    GITHUB_REPO=""
  elif ! gh auth status &>/dev/null; then
    warn "'gh' non è autenticata (esegui 'gh auth login' o esporta GH_TOKEN): salto la copia off-site, procedo solo con il backup locale."
    GITHUB_REPO=""
  fi
fi

mkdir -p "$BACKUP_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M)"
BACKED_UP=0
FAILED=0

docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" \
  || die "Container '${CONTAINER_NAME}' non in esecuzione: lo stack Jinbocho è attivo? (docker compose ... up -d)"

db_name="$(docker inspect "$CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_DB=' | cut -d= -f2-)"
db_user="$(docker inspect "$CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_USER=' | cut -d= -f2-)"
db_name="${db_name:-jinbocho}"
db_user="${db_user:-postgres}"

out_file="${BACKUP_DIR}/${db_name}_${TIMESTAMP}.dump.gz"
log "Backup di '${db_name}' (container ${CONTAINER_NAME}, tutti gli schemi in un unico snapshot) -> ${out_file}"

# -Fc (custom format): compresso di suo, ma pipeline comunque su gzip per
# coerenza col resto dello script (nome file .dump.gz) e con la retention
# locale/off-site sottostante, che opera per estensione.
if docker exec "$CONTAINER_NAME" pg_dump -U "$db_user" -Fc "$db_name" | gzip > "$out_file" && [[ -s "$out_file" ]]; then
  size="$(du -h "$out_file" | cut -f1)"
  log "  OK ${db_name} - ${size}"
  BACKED_UP=$((BACKED_UP + 1))
else
  warn "  pg_dump fallito o vuoto per ${db_name} (container ${CONTAINER_NAME})"
  rm -f "$out_file"
  FAILED=$((FAILED + 1))
fi

if [[ -n "$GITHUB_REPO" && "$BACKED_UP" -gt 0 ]]; then
  RELEASE_TAG="backup-${TIMESTAMP}"
  log "Pubblico i dump di questa run come release GitHub '${RELEASE_TAG}' su ${GITHUB_REPO}"
  if gh release create "$RELEASE_TAG" "${BACKUP_DIR}"/*"_${TIMESTAMP}.dump.gz" \
      --repo "$GITHUB_REPO" \
      --title "Backup ${TIMESTAMP}" \
      --notes "Backup automatico Jinbocho — ${BACKED_UP} database." &>/dev/null; then
    log "  OK release ${RELEASE_TAG} pubblicata"
  else
    warn "  Pubblicazione della release ${RELEASE_TAG} fallita"
    FAILED=$((FAILED + 1))
  fi
fi

if [[ "$RETENTION_DAYS" -gt 0 ]]; then
  log "Pulizia backup più vecchi di ${RETENTION_DAYS} giorni in ${BACKUP_DIR}"
  find "$BACKUP_DIR" -name '*.dump.gz' -mtime "+${RETENTION_DAYS}" -delete
fi

if [[ -n "$GITHUB_REPO" && "$RETENTION_DAYS" -gt 0 ]]; then
  log "Pulizia release più vecchie di ${RETENTION_DAYS} giorni su ${GITHUB_REPO}"
  CUTOFF_DATE="$(date -d "-${RETENTION_DAYS} days" +%Y%m%d)"
  gh release list --repo "$GITHUB_REPO" --limit 1000 --json tagName --jq '.[].tagName' 2>/dev/null \
    | while IFS= read -r tag; do
        [[ "$tag" =~ ^backup-([0-9]{8})_ ]] || continue
        tag_date="${BASH_REMATCH[1]}"
        if [[ "$tag_date" < "$CUTOFF_DATE" ]]; then
          log "  Rimuovo release ${tag} (${tag_date} < ${CUTOFF_DATE})"
          gh release delete "$tag" --repo "$GITHUB_REPO" --yes --cleanup-tag &>/dev/null \
            || warn "  Impossibile rimuovere la release ${tag}"
        fi
      done
fi

echo
log "Completato: ${BACKED_UP} backup riusciti, ${FAILED} falliti. Directory: ${BACKUP_DIR}"
[[ "$FAILED" -eq 0 ]]
