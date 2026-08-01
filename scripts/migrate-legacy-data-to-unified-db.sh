#!/usr/bin/env bash
#
# Jinbocho — ADR-018, fase locale/dev: copia i DATI (non lo schema, già
# creato da `alembic upgrade head` in ciascun servizio) dai vecchi volumi
# Postgres per-servizio (pre-unificazione) dentro lo schema corrispondente
# del nuovo database unico "jinbocho".
#
# Precondizioni:
#   - i vecchi container (jinbocho-postgres-auth/-catalog/-ai) sono stati
#     rimossi, ma i loro VOLUMI Docker sono ancora presenti sulla macchina
#     (li lascia intatti la migrazione ADR-018 già fatta — vedi `docker
#     volume ls | grep jinbocho_local_postgres`);
#   - il nuovo container "jinbocho-postgres" (db "jinbocho", schemi auth/
#     catalog/ai) è già up e le migration Alembic dei 3 servizi sono già
#     state applicate contro di esso (schemi/tabelle vuoti, pronti a
#     ricevere i dati).
#
# Questo script NON tocca produzione e NON è il runbook di produzione
# (ADR-018 lo tratta esplicitamente come lavoro futuro separato) — è solo
# per riportare i dati di sviluppo locale già inseriti prima del passaggio
# al DB unico.
#
# Come funziona, per ciascun servizio (auth, catalog, ai):
#   1. Avvia un container Postgres temporaneo che monta il vecchio volume
#      dati (nessuna porta pubblicata, nessuna rete: si opera solo via
#      `docker exec` sul socket unix locale del container, autenticazione
#      "trust" di default dell'immagine ufficiale — non servono password).
#   2. `pg_dump --data-only` dal vecchio DB (schema "public", l'unico che
#      esisteva prima di ADR-018).
#   3. Remap dello schema: gli unici punti in cui pg_dump qualifica
#      esplicitamente "public." in un dump data-only sono le righe
#      `COPY public.<tabella>` e `pg_catalog.setval('public.<sequenza>', ...)`
#      — si sostituiscono con un sed ancorato a inizio riga/pattern esatto,
#      MAI un replace generico di "public." nel file (rischierebbe di
#      toccare dati reali che contengono quella stringa).
#   4. Carico nel DB unico con `session_replication_role = replica`
#      (disabilita temporaneamente i trigger, inclusi i controlli di FK —
#      sicuro qui perché i dati erano già coerenti nel DB sorgente) dentro
#      UNA transazione per servizio: o va tutto o niente.
#   5. Verifica: conta le righe per tabella nel vecchio DB e nel nuovo
#      schema, segnala qualunque mismatch.
#   6. Ferma ed rimuove (--rm) il container temporaneo.
#
# Idempotenza: di default lo script SI RIFIUTA di caricare dati in uno
# schema che ha già righe, per evitare doppioni silenziosi. Passa
# --truncate-first per svuotare (TRUNCATE ... CASCADE) lo schema di
# destinazione prima del carico, se vuoi ripetere l'operazione.
#
# Uso:
#   ./scripts/migrate-legacy-data-to-unified-db.sh                 # tutti e 3
#   ./scripts/migrate-legacy-data-to-unified-db.sh --only catalog  # uno solo
#   ./scripts/migrate-legacy-data-to-unified-db.sh --dry-run       # solo conteggio righe, nessuna scrittura
#   ./scripts/migrate-legacy-data-to-unified-db.sh --truncate-first
#
set -euo pipefail

NEW_CONTAINER="jinbocho-postgres"
NEW_DB="jinbocho"

# Niente `declare -A`: il bash 3.2 di serie su macOS non supporta gli array
# associativi. service -> "vecchio_volume_docker:vecchio_nome_db:schema_destinazione"
legacy_info() {
  case "$1" in
    auth)    echo "jinbocho_local_postgres_auth_data:auth_db:auth" ;;
    catalog) echo "jinbocho_local_postgres_catalog_data:catalog_db:catalog" ;;
    ai)      echo "jinbocho_local_postgres_ai_data:ai_db:ai" ;;
    *)       return 1 ;;
  esac
}

ONLY=""
DRY_RUN=0
TRUNCATE_FIRST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --truncate-first) TRUNCATE_FIRST=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opzione sconosciuta: $1" >&2; exit 1 ;;
  esac
done

if ! docker inspect "$NEW_CONTAINER" >/dev/null 2>&1; then
  echo "Container '$NEW_CONTAINER' non trovato — deve essere up prima di lanciare questo script." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

MISMATCHES=0

migrate_one() {
  local svc="$1" volume="$2" old_db="$3" schema="$4"
  local tmp_container="jinbocho-migrate-tmp-${svc}"

  echo ""
  echo "== ${svc}: volume ${volume} -> schema ${schema} =="

  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "  volume '${volume}' non trovato — salto ${svc} (probabilmente mai esistito, es. ai in un'installazione solo Community)."
    return
  fi

  docker rm -f "$tmp_container" >/dev/null 2>&1 || true
  docker run -d --rm \
    --name "$tmp_container" \
    -e POSTGRES_DB="$old_db" \
    -e POSTGRES_PASSWORD=unused_local_socket_uses_trust_auth \
    -v "${volume}:/var/lib/postgresql/data" \
    postgres:16-alpine >/dev/null

  echo -n "  avvio Postgres legacy..."
  for _ in $(seq 1 30); do
    if docker exec "$tmp_container" pg_isready -U postgres >/dev/null 2>&1; then
      echo " pronto."
      break
    fi
    sleep 1
    echo -n "."
  done
  if ! docker exec "$tmp_container" pg_isready -U postgres >/dev/null 2>&1; then
    echo ""
    echo "  Postgres legacy non risponde dopo 30s, salto ${svc}." >&2
    docker stop "$tmp_container" >/dev/null 2>&1 || true
    return 1
  fi

  # tabelle presenti nel vecchio DB (schema public)
  local tables
  tables="$(docker exec "$tmp_container" psql -U postgres -d "$old_db" -tAc \
    "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1;")"

  if [[ -z "$tables" ]]; then
    echo "  nessuna tabella in ${old_db}.public — niente da migrare."
    docker stop "$tmp_container" >/dev/null 2>&1 || true
    return
  fi

  echo "  conteggio righe (vecchio -> nuovo):"
  local table row_count_old row_count_new
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    row_count_old="$(docker exec "$tmp_container" psql -U postgres -d "$old_db" -tAc \
      "SELECT count(*) FROM public.\"${table}\";")"
    if docker exec "$NEW_CONTAINER" psql -U postgres -d "$NEW_DB" -tAc \
        "SELECT to_regclass('${schema}.\"${table}\"') IS NOT NULL;" | grep -q 't'; then
      row_count_new="$(docker exec "$NEW_CONTAINER" psql -U postgres -d "$NEW_DB" -tAc \
        "SELECT count(*) FROM ${schema}.\"${table}\";")"
    else
      row_count_new="(tabella assente in ${schema} — controllare che le migration Alembic siano state applicate)"
    fi
    printf "    %-40s %8s -> %s\n" "$table" "$row_count_old" "$row_count_new"
  done <<< "$tables"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    docker stop "$tmp_container" >/dev/null 2>&1 || true
    return
  fi

  # rifiuta di sovrascrivere dati già presenti, a meno di --truncate-first
  local existing_rows
  existing_rows="$(docker exec "$NEW_CONTAINER" psql -U postgres -d "$NEW_DB" -tAc "
    SELECT COALESCE(sum(n_live_tup), 0)
    FROM pg_stat_user_tables
    WHERE schemaname = '${schema}';
  ")"
  existing_rows="$(echo "$existing_rows" | tr -d '[:space:]')"

  if [[ "${existing_rows:-0}" -gt 0 ]]; then
    if [[ "$TRUNCATE_FIRST" -eq 1 ]]; then
      echo "  schema '${schema}' non vuoto (~${existing_rows} righe stimate) — svuoto con --truncate-first."
      docker exec "$NEW_CONTAINER" psql -U postgres -d "$NEW_DB" -v ON_ERROR_STOP=1 -c "
        DO \$\$
        DECLARE r RECORD;
        BEGIN
          FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = '${schema}' LOOP
            EXECUTE format('TRUNCATE TABLE %I.%I CASCADE', '${schema}', r.tablename);
          END LOOP;
        END \$\$;
      "
    else
      echo "  schema '${schema}' contiene già dati (~${existing_rows} righe stimate)." >&2
      echo "  salto ${svc} per non duplicare — rilancia con --truncate-first se vuoi sovrascrivere." >&2
      docker stop "$tmp_container" >/dev/null 2>&1 || true
      MISMATCHES=1
      return
    fi
  fi

  local dump_file="${WORKDIR}/${svc}.sql"
  docker exec "$tmp_container" pg_dump -U postgres --data-only --no-owner --no-privileges "$old_db" \
    > "$dump_file"

  # remap dello schema: solo sui pattern esatti che pg_dump emette per un
  # dump data-only, mai un replace generico di "public." (vedi header).
  #
  # pg_dump (client 15+) apre il dump con
  # `SELECT pg_catalog.set_config('search_path', '', false);` per
  # sicurezza (protezione contro attacchi via search_path) — azzera il
  # search_path per tutto il resto dello script. Se una tabella ha indici
  # o default che chiamano funzioni non qualificate (es. `unaccent()`
  # dentro `immutable_unaccent` in catalog), il COPY fallisce perché quelle
  # funzioni non sono più risolvibili. Sostituiamo quella riga con un
  # search_path esplicito sullo schema di destinazione (+ public, dove
  # vivono le estension come unaccent/pg_trgm).
  sed -i.bak \
    -e "s/^COPY public\./COPY ${schema}./" \
    -e "s/pg_catalog\.setval('public\./pg_catalog.setval('${schema}./g" \
    -e "s/SELECT pg_catalog\.set_config('search_path', '', false);/SET search_path TO ${schema}, public;/" \
    "$dump_file"
  rm -f "${dump_file}.bak"

  echo "  carico in ${NEW_DB}.${schema} (trigger/FK disabilitati per la durata del carico, un'unica transazione)..."
  {
    echo "BEGIN;"
    echo "SET session_replication_role = replica;"
    cat "$dump_file"
    echo "SET session_replication_role = DEFAULT;"
    echo "COMMIT;"
  } | docker exec -i "$NEW_CONTAINER" psql -U postgres -d "$NEW_DB" -v ON_ERROR_STOP=1 -f -

  echo "  verifica post-carico:"
  local mismatch_here=0
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    row_count_old="$(docker exec "$tmp_container" psql -U postgres -d "$old_db" -tAc \
      "SELECT count(*) FROM public.\"${table}\";")"
    row_count_new="$(docker exec "$NEW_CONTAINER" psql -U postgres -d "$NEW_DB" -tAc \
      "SELECT count(*) FROM ${schema}.\"${table}\";")"
    if [[ "$row_count_old" == "$row_count_new" ]]; then
      printf "    OK    %-40s %s righe\n" "$table" "$row_count_new"
    else
      printf "    MISMATCH %-37s vecchio=%s nuovo=%s\n" "$table" "$row_count_old" "$row_count_new"
      mismatch_here=1
    fi
  done <<< "$tables"

  if [[ "$mismatch_here" -eq 1 ]]; then
    MISMATCHES=1
  fi

  docker stop "$tmp_container" >/dev/null 2>&1 || true
}

if [[ -n "$ONLY" ]]; then
  info="$(legacy_info "$ONLY")" || { echo "Servizio sconosciuto: '${ONLY}' (attesi: auth catalog ai)" >&2; exit 1; }
  IFS=':' read -r volume old_db schema <<< "$info"
  migrate_one "$ONLY" "$volume" "$old_db" "$schema"
else
  for svc in auth catalog ai; do
    IFS=':' read -r volume old_db schema <<< "$(legacy_info "$svc")"
    migrate_one "$svc" "$volume" "$old_db" "$schema"
  done
fi

echo ""
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry-run completato, nessuna scrittura effettuata."
elif [[ "$MISMATCHES" -eq 1 ]]; then
  echo "Migrazione completata con AVVISI — controlla i MISMATCH/skip sopra prima di considerare i vecchi volumi eliminabili." >&2
  exit 1
else
  echo "Migrazione completata, conteggi righe verificati. I vecchi volumi Docker (jinbocho_local_postgres_{auth,catalog,ai}_data) non sono stati toccati — rimuovili manualmente solo dopo aver verificato l'app con i dati migrati."
fi
