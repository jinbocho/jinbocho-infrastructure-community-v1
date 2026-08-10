#!/bin/bash
# ADR-018: first-boot bootstrap for the single "jinbocho" database.
#
# Creates one Postgres SCHEMA + one least-privilege LOGIN ROLE per former
# per-service database (auth, catalog, ai), each role granted only on its
# own schema (ADR-018 decision point 3). Runs once, automatically, via
# docker-entrypoint-initdb.d on first container boot against the database
# named by $POSTGRES_DB.
#
# Runs unconditionally (all three schemas/roles are created even on a
# Community-only install with no ai-service running) so the schema layout
# never depends on which edition/overlay is active — see the note in
# docker-compose.pro-local-overlay.yml.
#
# Idempotent: IF NOT EXISTS / a DO block guard everything, since Postgres
# init scripts have no "already ran" tracking beyond "the data dir was
# empty" — safe to leave mounted even if the image is ever reused.
#
# Role passwords reuse $POSTGRES_PASSWORD for local-dev simplicity (one
# secret to manage instead of four). Revisit with per-role secrets before
# this script is ever adapted for the production migration (ADR-018 §4,
# not yet planned).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
    CREATE SCHEMA IF NOT EXISTS auth;
    CREATE SCHEMA IF NOT EXISTS catalog;
    CREATE SCHEMA IF NOT EXISTS ai;

    -- catalog-service's own migrations (0024, 0026 — pre-ADR-018, not
    -- rewritten per the project's standing rule against editing
    -- already-shipped migrations) run "CREATE EXTENSION IF NOT EXISTS"
    -- for these two. Unlike CREATE SCHEMA, Postgres checks existence
    -- before the privilege check for CREATE EXTENSION IF NOT EXISTS, so
    -- pre-creating them here (as superuser, once) is enough — catalog_role
    -- never needs database-level CREATE to run those migrations itself.
    -- Explicit WITH SCHEMA public: catalog_role's search_path includes
    -- public precisely so these extension functions stay reachable
    -- unqualified (see ALTER ROLE below).
    CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;
    CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

    -- auth-service's coordinates migration (ADR-020 amendment: real
    -- geolocation) runs "CREATE EXTENSION IF NOT EXISTS" for these two —
    -- same reasoning as unaccent/pg_trgm above: pre-created here as
    -- superuser so auth_role never needs database-level CREATE to run that
    -- migration itself. cube/earthdistance are the trusted Postgres contrib
    -- extensions behind ll_to_earth()/earth_distance(), used for the
    -- "nearby" radius query — no PostGIS, no external service.
    CREATE EXTENSION IF NOT EXISTS cube WITH SCHEMA public;
    CREATE EXTENSION IF NOT EXISTS earthdistance WITH SCHEMA public;

    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'auth_role') THEN
            CREATE ROLE auth_role LOGIN PASSWORD '${POSTGRES_PASSWORD}';
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'catalog_role') THEN
            CREATE ROLE catalog_role LOGIN PASSWORD '${POSTGRES_PASSWORD}';
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ai_role') THEN
            CREATE ROLE ai_role LOGIN PASSWORD '${POSTGRES_PASSWORD}';
        END IF;
    END
    \$\$;

    -- Each role may create/use objects only in its own schema. No role is
    -- granted anything on the other two schemas, and PUBLIC has no implicit
    -- CREATE on any of them (Postgres 15+ default) — this is the enforcement
    -- ADR-018's "Losses/risks" section says replaces the removed network
    -- boundary. It is defence in depth, not process isolation: all three
    -- roles still share one connection pool at the Postgres level and one
    -- physical process (the postgres server), unlike the pre-ADR-018 setup
    -- where each service's own container had no path to the others' data
    -- at all.
    GRANT USAGE, CREATE ON SCHEMA auth TO auth_role;
    GRANT USAGE, CREATE ON SCHEMA catalog TO catalog_role;
    GRANT USAGE, CREATE ON SCHEMA ai TO ai_role;

    -- Session default so a bare "psql -U auth_role jinbocho" (or a driver
    -- that doesn't set server_settings.search_path itself) still resolves
    -- unqualified table names to the right schema. app/infrastructure/
    -- database/session.py additionally sets this per-connection explicitly
    -- (ADR-018 decision point 1) — belt and suspenders, not redundant: the
    -- role default covers migrations/psql/anything that isn't the app.
    -- "public" stays second in the path (not first, so an unqualified
    -- table name never silently resolves to a same-named public object
    -- ahead of the role's own schema) purely so extension functions
    -- installed into public (unaccent, pg_trgm — see below) stay visible;
    -- no service tables live in public, only extension objects.
    ALTER ROLE auth_role SET search_path TO auth, public;
    ALTER ROLE catalog_role SET search_path TO catalog, public;
    ALTER ROLE ai_role SET search_path TO ai, public;

    ALTER DEFAULT PRIVILEGES FOR ROLE auth_role IN SCHEMA auth GRANT ALL ON TABLES TO auth_role;
    ALTER DEFAULT PRIVILEGES FOR ROLE catalog_role IN SCHEMA catalog GRANT ALL ON TABLES TO catalog_role;
    ALTER DEFAULT PRIVILEGES FOR ROLE ai_role IN SCHEMA ai GRANT ALL ON TABLES TO ai_role;

    ALTER DEFAULT PRIVILEGES FOR ROLE auth_role IN SCHEMA auth GRANT ALL ON SEQUENCES TO auth_role;
    ALTER DEFAULT PRIVILEGES FOR ROLE catalog_role IN SCHEMA catalog GRANT ALL ON SEQUENCES TO catalog_role;
    ALTER DEFAULT PRIVILEGES FOR ROLE ai_role IN SCHEMA ai GRANT ALL ON SEQUENCES TO ai_role;
SQL
