# jinbocho-infrastructure-v1 (Community Edition)

Docker Compose orchestration for the Jinbocho microservices (`auth`, `catalog`,
`api-gateway`) and the VPS/Render deploy tooling for the **Community edition**.
No application code lives here — see the sibling `jinbocho-*` repos for that.

> An optional AI module (book tagging, dedup suggestions) exists under a
> separate commercial license. It is not part of this repo — contact
> jinbochoapp@gmail.com for details.

## Which compose file do I need?

| File | Images | Use case |
|---|---|---|
| `docker/docker-compose.community.yml` | GHCR (pre-built) | Self-host, no source checkout |
| `docker/docker-compose.community.local.yml` | Built from `../jinbocho-*-v1` | Local dev from source |
| `docker/docker-compose.all.yml` | GHCR backend + locally-built frontend | Single-server VPS deploy, includes Caddy + TLS |

All commands below are run from the repo root.

## 1. Quick start — self-host with pre-built images

```bash
git clone https://github.com/jinbocho/jinbocho-infrastructure-v1.git
cd jinbocho-infrastructure-v1

cp .env.example .env
cp envs/auth-service.env.example envs/auth-service.env
cp envs/catalog-service.env.example envs/catalog-service.env
cp envs/api-gateway.env.example envs/api-gateway.env

docker compose -f docker/docker-compose.community.yml up -d
```

Open **http://localhost:8000/docs**.

```bash
docker compose -f docker/docker-compose.community.yml logs -f   # tail logs
docker compose -f docker/docker-compose.community.yml ps        # service status
docker compose -f docker/docker-compose.community.yml down      # stop (volumes are kept)
```

## 2. Environment variables

Each file below is gitignored; copy it from the matching `*.example` and edit
it. Variables not listed here already have a working default in the
`*.example` file — you don't need to touch them for local dev.

### `.env` (repo root — read by Docker Compose itself)

| Variable | Default | Required | Used by | Description |
|---|---|---|---|---|
| `POSTGRES_PASSWORD` | `change_me_local_dev` | Always | all compose files | Password for the local Postgres containers |
| `JWT_SECRET_KEY` | — | No (manual use) | `docker-compose.all.yml` flows | Set automatically by `setup-vps-community.sh`; for manual setups set it in each service's `envs/*.env` instead (see below) |
| `JINBOCHO_VERSION` | `latest` | No | `docker-compose.all.yml`, `*.community.yml` | GHCR image tag to pull |
| `DOMAIN` | — | Only for VPS w/ TLS | `docker-compose.all.yml` | Public hostname, set by `setup-vps-community.sh` |
| `VITE_API_BASE_URL` | — | Only for `all.yml` | `docker-compose.all.yml` (frontend build) | Public API base URL baked into the frontend build |

### `envs/auth-service.env`

| Variable | Default | Required | Description |
|---|---|---|---|
| `DEBUG` | `true` | No | Set `false` in production; enables SQL logging |
| `DATABASE_URL` | `postgresql+asyncpg://postgres:YOUR_POSTGRES_PASSWORD@jinbocho-postgres-auth:5432/auth_db` | Yes | Must match `POSTGRES_PASSWORD` from root `.env` for local dev |
| `JWT_SECRET_KEY` | — | **Yes** | Must be **identical** across `auth-service`, `catalog-service`, `api-gateway`. Generate with `openssl rand -hex 32` |
| `INTERNAL_SERVICE_TOKEN` | — | **Yes** | Must match `catalog-service`'s value — authenticates catalog→auth calls (loan reminder emails). Generate with `openssl rand -hex 32` |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | `30` | No | Access token lifetime |
| `REFRESH_TOKEN_EXPIRE_DAYS` | `30` | No | Refresh token lifetime |
| `FRONTEND_BASE_URL` | `http://localhost:5173` | No | Used to build links in invite/reset-password emails |
| `SMTP_HOST` | `smtp.gmail.com` | No | Leave `SMTP_USER` empty to print links to logs instead of sending email |
| `SMTP_PORT` | `587` | No | — |
| `SMTP_USER` | — | No (required to actually send email) | Gmail address |
| `SMTP_PASSWORD` | — | No (required to actually send email) | Gmail **app** password |
| `EMAIL_FROM` | — | No | From address on outgoing emails |

### `envs/catalog-service.env`

| Variable | Default | Required | Description |
|---|---|---|---|
| `DEBUG` | `true` | No | Set `false` in production |
| `DATABASE_URL` | `postgresql+asyncpg://postgres:YOUR_POSTGRES_PASSWORD@jinbocho-postgres-catalog:5432/catalog_db` | Yes | Must match `POSTGRES_PASSWORD` from root `.env` for local dev |
| `AUTH_SERVICE_URL` | `http://jinbocho-auth:8001` | No | Internal Docker network address |
| `JWT_SECRET_KEY` | — | **Yes** | Must match `auth-service`'s value — generate with `openssl rand -hex 32` |
| `JWT_ALGORITHM` | `HS256` | No | — |
| `INTERNAL_SERVICE_TOKEN` | — | **Yes** | Must match `auth-service`'s value — authenticates catalog→auth calls (loan reminder emails). Generate with `openssl rand -hex 32` |
| `LOAN_REMINDER_LEAD_DAYS` | `1` | No | Days before `due_date` the loan-reminder email job fires |
| `JINBOCHO_FEATURES` | `catalog,auth` | No | Must match `api-gateway`'s value |
| `GOOGLE_BOOKS_API_KEY` | — | Recommended | Free key at [console.cloud.google.com](https://console.cloud.google.com/) (Books API). Without it the shared quota (1000 req/day) is exhausted quickly |

### `envs/api-gateway.env`

| Variable | Default | Required | Description |
|---|---|---|---|
| `DEBUG` | `true` | No | Set `false` in production |
| `JWT_SECRET_KEY` | — | **Yes** | Must match `auth-service`'s value — generate with `openssl rand -hex 32` |
| `AUTH_SERVICE_URL` | `http://auth-service:8001` | No | Internal Docker network address — leave as-is for local dev |
| `CATALOG_SERVICE_URL` | `http://catalog-service:8002` | No | Internal Docker network address — leave as-is for local dev |
| `CORS_ORIGINS` | `["*"]` | No | Set to your frontend URL in production, e.g. `["https://your-fe.onrender.com"]` |
| `JINBOCHO_FEATURES` | `catalog,auth` | No | Comma-separated enabled modules |

## 3. Developing from source (sibling checkouts)

Requires `../jinbocho-auth-v1`, `../jinbocho-catalog-v1`, `../jinbocho-api-gateway-v1`
checked out next to this repo.

```bash
docker compose -f docker/docker-compose.community.local.yml up --build -d

# Stop:
docker compose -f docker/docker-compose.community.local.yml down
```

Or run backend + frontend (`npm run dev`) together:

```bash
./scripts/dev.sh
```

## 4. One-shot VPS install

Drives `docker/docker-compose.all.yml` end to end: installs Docker if needed,
generates secrets, writes `.env` and `envs/*.env`, and brings the stack up
behind Caddy (automatic Let's Encrypt TLS when `--domain` is a real hostname).

```bash
sudo ./scripts/setup-vps-community.sh \
  --domain library.example.com \
  --email you@example.com \
  --google-books-key AIza...
```

Run the script with `--help` to see all flags (SMTP setup, frontend URL
override, firewall, etc).

### Full one-shot command (fresh VPS, nothing checked out yet)

Clones this repo and runs the installer with every optional flag spelled
out — replace the placeholders, drop the flags you don't need:

```bash
git clone https://github.com/jinbocho/jinbocho-infrastructure-v1.git && \
cd jinbocho-infrastructure-v1 && \
sudo ./scripts/setup-vps-community.sh \
  --domain <YOUR_DOMAIN> \
  --email <LETSENCRYPT_EMAIL> \
  --google-books-key <GOOGLE_BOOKS_API_KEY> \
  --smtp-user <GMAIL_ADDRESS> \
  --smtp-password <GMAIL_APP_PASSWORD> \
  --email-from <FROM_EMAIL_ADDRESS> \
  --frontend-base-url <PUBLIC_FRONTEND_URL> \
  --version <IMAGE_TAG> \
  --enable-firewall \
  --non-interactive
```

| Placeholder | Notes |
|---|---|
| `<YOUR_DOMAIN>` | Must already point to the server's IP. Omit `--domain`/`--email` to use the bare IP over HTTP instead |
| `<LETSENCRYPT_EMAIL>` | Required only if `--domain` is set |
| `<GOOGLE_BOOKS_API_KEY>` | From [console.cloud.google.com](https://console.cloud.google.com/) — can be added later |
| `<GMAIL_ADDRESS>` / `<GMAIL_APP_PASSWORD>` | Optional — omit to fall back to logging invite/reset links instead of emailing them |
| `<FROM_EMAIL_ADDRESS>` | Optional, defaults to `<GMAIL_ADDRESS>` |
| `<PUBLIC_FRONTEND_URL>` | Optional, defaults to the derived domain/IP URL |
| `<IMAGE_TAG>` | Optional, defaults to `latest` |

`--enable-firewall` opens 22/80/443 via `ufw`; drop it if you manage the
firewall elsewhere. `--non-interactive` skips all prompts and relies only on
the flags passed in.

## 5. Smoke-test a running stack

```bash
./scripts/validate-api.sh
```

Registers a test family and exercises the main endpoints through the gateway
(`http://localhost:8000`).

---

License: see [LICENSE](LICENSE). Contributing: see [CONTRIBUTING.md](CONTRIBUTING.md).
