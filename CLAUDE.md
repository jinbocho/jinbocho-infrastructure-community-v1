# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo (`jinbocho-infrastructure-v1`) holds **orchestration only** — no application
code. It assembles the sibling Community-edition service repos (`../jinbocho-auth-v1`,
`../jinbocho-catalog-v1`, `../jinbocho-api-gateway-v1`, `../jinbocho-fe`) via Docker
Compose, plus VPS install scripts, a Render Blueprint, and DB backup tooling. All four
repos are expected to be checked out as siblings under the same parent directory.

This is the **Community edition** — free, no AI module. An optional AI module exists
under a separate commercial license and is not part of this repo.

## Compose file matrix

| File | Images | Use case |
|------|--------|----------|
| `docker-compose.community.yml` | GHCR (pre-built) | Self-host, no source checkout |
| `docker-compose.community.local.yml` | Built from `../jinbocho-*-v1` | Local dev, contributors — **this is what `scripts/dev.sh` uses** |
| `docker-compose.all.yml` | GHCR backend + locally-built frontend | Single-server VPS deploy, includes Caddy reverse proxy + TLS |

Backend services never publish ports beyond `127.0.0.1` (or not at all in `.all.yml`) —
the api-gateway (`:8000`, or Caddy `:80`/`:443` in `.all.yml`) is the only intended public
entry point. ADR-018 (database unification, live in production since 2026-08-01 — see
`jinbocho-docs/architecture/PRODUCTION_DB_UNIFICATION_RUNBOOK.md`): one Postgres
container/database (`postgres`, database `jinbocho`) shared by auth/catalog/ai, each
isolated in its own Postgres SCHEMA + least-privilege ROLE, provisioned by
`init-sql/00-schemas-and-roles.sh` (first-boot SQL) and one named volume.

All three compose files also define a `netdata` service (single container — host +
per-container metrics via `/proc`, `/sys` and the Docker socket, built-in dashboard on
`:19999`) gated behind the `observability` Compose profile, off by default. Enable with
`--profile observability` on any `docker compose` invocation. The dashboard binds to
`127.0.0.1:19999` only — reach it via `ssh -L 19999:localhost:19999 <host>`, then
`http://localhost:19999`, no auth/exposure config needed.

Replaced the Grafana Alloy/node-exporter/cadvisor/postgres-exporter stack (ADR-012) on
2026-08-01 — that setup shipped metrics/traces/logs to Grafana Cloud; this is
local-only and much lighter for a single-VPS deployment. `dashboards/` (the old Grafana
Cloud JSON exports) and ADR-012 itself are now historical — not deleted, but describe the
superseded setup.

## Common commands

```bash
# Local dev: backend (Docker Compose) + frontend (npm run dev)
./scripts/dev.sh

# Backend only, from local source checkouts:
docker compose -f docker-compose.community.local.yml up --build -d
docker compose -f docker-compose.community.local.yml down

# Smoke-test a running stack through the gateway (registers a family, exercises most endpoints):
./scripts/validate-api.sh

# One-shot install on a fresh VPS (drives docker-compose.all.yml):
sudo ./scripts/setup-vps-community.sh --domain library.example.com --email you@example.com --google-books-key AIza...

# Manual deploy of the all-in-one stack (what the setup script generates):
docker compose -f docker-compose.all.yml --env-file .env up -d --build

# Backup all running jinbocho-postgres-* containers (cron-able), optional off-site copy to GitHub Releases:
./scripts/backup-db.sh
./scripts/backup-db.sh --backup-dir /var/backups/jinbocho --retention-days 14 --github-repo jinbocho/jinbocho-db-backups
```

There is no build/lint/test suite in this repo itself — those live in each service repo.

## Environment configuration

- Root `.env` (copy from `.env.example`) is read by Docker Compose for variable
  substitution (currently just `POSTGRES_PASSWORD` for local dev Postgres containers, and
  `JINBOCHO_VERSION`/`VITE_API_BASE_URL` for `docker-compose.all.yml`).
- `envs/<service>.env` (copied from `envs/<service>.env.example`, gitignored) is the
  per-service env file consumed via `env_file:` in every compose variant.
- `JWT_SECRET_KEY` **must be identical** across `auth-service`, `catalog-service`, and
  `api-gateway` — tokens issued by one are validated by the others.

## Deployment targets

1. **Self-host VPS** — `docker-compose.all.yml` + Caddy, driven by
   `scripts/setup-vps-community.sh`. Caddy auto-provisions Let's Encrypt TLS when
   `--domain` is a real hostname; omit it to stand up over plain HTTP on the server's IP
   first.
2. **GHCR-only self-host** — `docker-compose.community.yml`, no frontend container (BYO
   frontend hosting), API-only.
3. **Render** (managed cloud) — `render.yaml` Blueprint.
   `.github/workflows/wake-render.yml` pings all Render service `/health` endpoints
   (free-tier services sleep) and the frontend, polling up to 90s each.
4. **Render DB backups** — `.github/workflows/db-backup.yml` runs nightly at 02:00 UTC,
   `pg_dump`s the Neon-hosted `auth_db`/`catalog_db` (requires `NEON_AUTH_DB_URL` /
   `NEON_CATALOG_DB_URL` repo secrets — use the raw `postgresql://` URL, not the
   asyncpg-transformed one the services use) and uploads the gzipped dumps as 90-day
   workflow artifacts.

## Working across the sibling repos

When a change here depends on a service-side change (e.g. a new env var, a new exposed
port, a new endpoint exercised by `validate-api.sh`), check the corresponding sibling repo
(`../jinbocho-auth-v1`, etc.) — this repo only wires services together, it doesn't define
their behavior.
