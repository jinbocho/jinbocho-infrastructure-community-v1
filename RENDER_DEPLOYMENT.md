# Jinbocho — Deploy su Render.com (Community Edition)

Piano completo per pubblicare lo stack Community (3 backend + gateway + frontend + database) su Render.

---

## 0. Topologia su Render

| Componente | Tipo / Provider | Pubblico? | Porta |
|------------|-----------------|-----------|-------|
| `auth_db` | PostgreSQL su **Neon** (non Render — §2) | no | — |
| `catalog_db` | PostgreSQL su **Neon** | no | — |
| `jinbocho-auth` | Private Service (Docker) | no (solo rete interna) | 8001 |
| `jinbocho-catalog` | Private Service (Docker) | no | 8002 |
| `jinbocho-api-gateway` | **Web Service** (Docker) | **sì** | $PORT |
| `jinbocho-fe` | **Static Site** | **sì** | — |

**Solo due componenti sono pubblici**: il gateway (API) e il frontend. I due backend sono *Private Services* — raggiungibili solo dalla rete interna di Render, quindi mai esposti a internet. Il gateway è l'unico ingresso alle API.

---

## 1. Pre-requisiti (prima di toccare Render)

### 1.1 Genera i segreti
Servono **una sola volta**, da riusare identici su più servizi:

```bash
# JWT_SECRET_KEY — DEVE essere identico su auth, catalog e gateway
openssl rand -hex 32
```

Annota il valore: lo chiameremo `<JWT_SECRET>` nel resto del documento.

### 1.2 Account
- Crea un account su [render.com](https://render.com) (il piano free basta per iniziare; vedi §8 sui limiti).
- Collega il tuo GitHub/GitLab: ogni repo (`jinbocho-auth-v1`, `jinbocho-catalog-v1`, `jinbocho-api-gateway-v1`, `jinbocho-fe`) deve essere su un remote raggiungibile da Render.

### 1.3 Fix pre-deploy

**A) Binding alla porta di Render — ✅ GIÀ RISOLTO nel codice.** I 3 Dockerfile sono stati portati in forma shell `--port ${PORT:-XXXX}`: usano `$PORT` iniettato da Render e ricadono sulla porta locale (8000-8002) in docker-compose. Nessun *Docker Command* override necessario su Render.

**B) Migrazioni Alembic — ✅ GIÀ RISOLTO nel codice (auth + catalog).** Il CMD di auth e catalog ora esegue `alembic upgrade head &&` prima di avviare uvicorn: lo schema è sempre aggiornato all'avvio, sia in locale che su Render. Nessun *Pre-Deploy Command* necessario. (`gateway` non ha DB.)

**C) `DEBUG=false` in produzione** — l'unico fix che resta lato configurazione: nelle env files locali è `true` (logga tutto l'SQL), ma nelle env di Render va impostato `false` (vedi §5). Non è una modifica al codice perché `DEBUG` si controlla via variabile d'ambiente.

> Nota: con il fix B le migrazioni ora girano anche in locale a ogni `docker compose up` (prima erano manuali). È un miglioramento — il DB healthcheck garantisce che Postgres sia pronto prima dell'avvio.

---

## 2. Creazione dei Database — Neon (NON Render)

⚠️ **Il PostgreSQL Free di Render scade dopo ~30 giorni** (il DB viene cancellato). Per dati persistenti senza costi usiamo **[Neon](https://neon.tech)**: Postgres serverless, free tier che **non scade**, scala a zero quando inattivo (riavvio ~0.5s). Render ospita solo i servizi applicativi; i dati vivono su Neon.

### 2.1 Crea il progetto e i 2 database
1. Registrati su [neon.tech](https://neon.tech) → **Create project**
   - **Name**: `jinbocho`
   - **Postgres version**: 16
   - **Region**: la più vicina ai servizi Render (es. EU se Render è in Frankfurt)
2. Alla creazione, Neon crea un database di default. Crea i due che servono dalla **SQL Editor** o **Databases → New Database**:
   - `auth_db`
   - `catalog_db`

   Vivono nella stessa istanza (compute condiviso) ma restano logicamente isolati — un DB per servizio, come richiede l'architettura.

### 2.2 Ottieni e adatta le connection string
Per ogni database: **Dashboard → Connection Details** → seleziona il database → copia la stringa. Neon la fornisce così:
```
postgresql://user:password@ep-xxxx.eu-central-1.aws.neon.tech/auth_db?sslmode=require
```

**Trasformala in 2 passi** (obbligatorio per asyncpg):
1. `postgresql://` → `postgresql+asyncpg://`
2. `?sslmode=require` → `?ssl=require`   ← **critico**: asyncpg non capisce `sslmode`, crasha all'avvio

Risultato finale (= valore `DATABASE_URL` del servizio):
```
postgresql+asyncpg://user:password@ep-xxxx.eu-central-1.aws.neon.tech/auth_db?ssl=require
```

Ripeti cambiando solo il nome del database (`/catalog_db`).

> **Usa l'endpoint diretto, non quello "pooled"**: il pooler di Neon (PgBouncer transaction-mode) non è compatibile con i prepared statement di asyncpg senza config extra. Per il traffico di una libreria familiare l'endpoint diretto è più che sufficiente. Se in futuro ti serve il pooler, aggiungi `&prepared_statement_cache_size=0` all'URL.

> Le migrazioni Alembic (fix B) girano sullo stesso `DATABASE_URL` all'avvio del servizio → lo schema viene creato su Neon al primo deploy, **senza setup manuale**.

---

## 3. Deploy dei backend — ordine: auth → catalog → gateway

L'ordine conta: il gateway ha bisogno degli indirizzi interni degli altri.

### 3.1 `jinbocho-auth` (Private Service)
1. **New +** → **Private Service**
2. **Connect repository**: `jinbocho-auth-v1`
3. **Runtime**: Docker
4. **Region**: la stessa dei DB
5. **Instance Type**: Free/Starter
6. Sezione **Environment** → aggiungi le variabili (§5.1)
7. *Docker Command* e *Pre-Deploy*: **lascia vuoti** (già nel Dockerfile)
8. **Create**
9. Dopo il primo deploy, copia l'**indirizzo interno** del servizio (pagina servizio → in alto, formato `jinbocho-auth:8001` oppure un host `.internal`). Serve al gateway e al catalog.

### 3.2 `jinbocho-catalog` (Private Service)
Identico, ma:
- Repo: `jinbocho-catalog-v1`
- Env: §5.2 (include `AUTH_SERVICE_URL` = indirizzo interno di auth, e la `GOOGLE_BOOKS_API_KEY`)

### 3.3 `jinbocho-api-gateway` (Web Service — PUBBLICO)
1. **New +** → **Web Service** (non Private!)
2. Repo: `jinbocho-api-gateway-v1`, Runtime Docker, stessa region
3. Env: §5.3 (gli URL interni di auth/catalog + `JWT_SECRET` + `CORS_ORIGINS`)
4. *Docker Command*: **vuoto** (già nel Dockerfile)
5. **Health Check Path**: `/health`
6. **Create** → Render assegna un URL pubblico tipo `https://jinbocho-api-gateway.onrender.com`. **Annotalo**: è il `VITE_API_BASE_URL` del frontend.

---

## 4. Riepilogo impostazioni per servizio

Docker Command e migrazioni sono **già nel Dockerfile** (fix A+B) — su Render lascia i campi *Docker Command* e *Pre-Deploy* **vuoti**, usano il default dell'immagine.

| Servizio | Tipo | Docker Command su Render | Migrazioni | Health |
|----------|------|--------------------------|------------|--------|
| auth | Private | *(vuoto — dal Dockerfile)* | nel CMD (automatiche) | — |
| catalog | Private | *(vuoto — dal Dockerfile)* | nel CMD (automatiche) | — |
| gateway | Web (pubblico) | *(vuoto — dal Dockerfile)* | n/a (no DB) | `/health` |

---

## 5. Variabili d'ambiente per servizio

> `<JWT_SECRET>` = lo stesso valore generato in §1.1, **identico** su auth/catalog/gateway.
> `<X_INTERNAL>` = l'indirizzo interno Render del servizio X (copiato dal dashboard, es. `http://jinbocho-auth:8001`).

### 5.1 jinbocho-auth
```
DEBUG=false
DATABASE_URL=postgresql+asyncpg://...neon.tech/auth_db?ssl=require   # Neon URL adattato (§2.2)
JWT_SECRET_KEY=<JWT_SECRET>
JWT_ALGORITHM=HS256
JWT_ISSUER=jinbocho-auth
JWT_AUDIENCE=jinbocho
ACCESS_TOKEN_EXPIRE_MINUTES=30
REFRESH_TOKEN_EXPIRE_DAYS=30
PORT=8001
```

### 5.2 jinbocho-catalog
```
DEBUG=false
DATABASE_URL=postgresql+asyncpg://...neon.tech/catalog_db?ssl=require   # Neon URL adattato (§2.2)
AUTH_SERVICE_URL=<AUTH_INTERNAL>                     # es. http://jinbocho-auth:8001
JWT_SECRET_KEY=<JWT_SECRET>                          # IDENTICO ad auth
JWT_ALGORITHM=HS256
JWT_ISSUER=jinbocho-auth
JWT_AUDIENCE=jinbocho
GOOGLE_BOOKS_API_KEY=<la-tua-chiave-google-books>
PORT=8002
```

### 5.3 jinbocho-api-gateway
```
DEBUG=false
JWT_SECRET_KEY=<JWT_SECRET>                          # IDENTICO ad auth
JWT_ALGORITHM=HS256
AUTH_SERVICE_URL=<AUTH_INTERNAL>
CATALOG_SERVICE_URL=<CATALOG_INTERNAL>
CORS_ORIGINS=["https://jinbocho-fe.onrender.com"]    # URL pubblico del FE (§6) — niente "*"
```

### 5.4 jinbocho-fe (Static Site)
```
VITE_API_BASE_URL=https://jinbocho-api-gateway.onrender.com   # URL pubblico del gateway (§3.3)
```
⚠️ Vite **inlina** le variabili `VITE_` al momento del *build*. Se cambi questo valore devi rifare il deploy (Clear cache & deploy).

---

## 6. Deploy del Frontend (Static Site)

Il FE ha già un `render.yaml`. Procedi:

1. **New +** → **Static Site**
2. Repo: `jinbocho-fe`
3. **Build Command**: `npm ci && npm run build`
4. **Publish Directory**: `dist`
5. **Environment** → `VITE_API_BASE_URL` = URL pubblico del gateway (§5.4)
6. Il rewrite SPA (`/* → /index.html`) è già nel `render.yaml`; se crei a mano, aggiungi una **Redirect/Rewrite Rule**: Source `/*`, Destination `/index.html`, Action **Rewrite**.
7. **Create** → URL pubblico tipo `https://jinbocho-fe.onrender.com`.

> Catena circolare di URL: il FE ha bisogno dell'URL del gateway, e il gateway (CORS) dell'URL del FE. Soluzione: deploya il gateway, copia il suo URL nel FE, deploya il FE, copia il suo URL in `CORS_ORIGINS` del gateway, e fai *redeploy* del gateway.

---

## 7. Verifica post-deploy

```bash
# 1. Gateway up
curl https://jinbocho-api-gateway.onrender.com/health

# 2. Registrazione famiglia (crea il primo admin)
curl -X POST https://jinbocho-api-gateway.onrender.com/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"family_name":"Test","email":"me@example.com","full_name":"Me"}'

# 3. Apri il FE nel browser e fai login
open https://jinbocho-fe.onrender.com
```

Checklist:
- [ ] `/health` del gateway risponde `{"status":"ok"}`
- [ ] Migrazioni applicate (i log dei Private Services mostrano `alembic upgrade head` ok)
- [ ] Login dal FE funziona (token JWT accettato dal catalog → stesso `JWT_SECRET` + `aud`/`iss`)
- [ ] Lookup ISBN funziona (Google Books key presente)
- [ ] Nessun errore CORS in console browser (origine FE in `CORS_ORIGINS`)

---

## 8. Note sui costi e limiti (piano Free)

- **Database → Neon Free** (§2): **non scade**, persistente, 0.5 GB. Risolve il problema dei 30 giorni del Postgres Render. Costo: €0.
- **Web/Private Services Free (Render)**: vanno in *sleep* dopo 15 min di inattività → primo accesso lento (cold start ~30-60s). Per un uso familiare è tollerabile; per evitarlo: piano Starter ($7/mo per servizio).
- **Stima costi**: con Neon (DB gratis) + Render Free (servizi) → **€0/mese**, accettando i cold-start. Per i soli servizi "sempre attivi" su Render Starter: ~$7/mo per servizio (il DB resta gratis su Neon).
- **Region**: tieni i servizi Render nella **stessa region** (i Private Services si vedono solo tra loro nella stessa region) e scegli la region Neon più vicina per ridurre la latenza DB.

---

## 9. Blueprint IaC — `render.yaml` (modo consigliato)

Il file [`render.yaml`](./render.yaml) in questo repo definisce l'intero stack Community (auth, catalog, gateway, FE) come Infrastructure-as-Code: crei tutto in un colpo invece che servizio per servizio.

### Procedura
1. **Sostituisci `CHANGEME`** con il tuo org/utente GitHub in ogni `repo:` del `render.yaml`, e `branch:` se non usi `main`. Committa e pusha.
2. Render Dashboard → **New + → Blueprint** → seleziona il repo `jinbocho-infrastructure-v1`.
3. Render legge `render.yaml` e mostra i servizi che creerà. Conferma.
4. **Inserisci i segreti** (`sync: false`) quando richiesto:
   | Variabile | Dove | Valore |
   |-----------|------|--------|
   | `JWT_SECRET_KEY` (gruppo `jinbocho-jwt`) | una volta sola | il secret generato (32 byte hex) |
   | `DATABASE_URL` (auth) | servizio auth | `postgresql+asyncpg://...neon.tech/auth_db?ssl=require` |
   | `DATABASE_URL` (catalog) | servizio catalog | `postgresql+asyncpg://...neon.tech/catalog_db?ssl=require` |
   | `GOOGLE_BOOKS_API_KEY` | servizio catalog | la tua chiave |
   | `CORS_ORIGINS` | gateway | lascia placeholder, lo metti al passo 6 |
   | `VITE_API_BASE_URL` | FE | lascia placeholder, lo metti al passo 6 |
5. **Primo deploy** → i 4 servizi partono. Auth e catalog applicano le migrazioni su Neon all'avvio (fix B).
6. **Chiudi il loop URL** (la dipendenza circolare FE↔gateway):
   - Copia l'URL pubblico del gateway → impostalo come `VITE_API_BASE_URL` del FE → *Manual Deploy* del FE
   - Copia l'URL pubblico del FE → mettilo in `CORS_ORIGINS` del gateway come `["https://<fe>.onrender.com"]` → *Manual Deploy* del gateway
7. Verifica con la checklist §7.

### Note
- **Free tier**: i backend sono `type: web` perché i *Private Services* di Render sono a pagamento. Si parlano via indirizzo interno `http://jinbocho-auth:8001` / `:8002`. Per nasconderli da internet (difesa in profondità) cambia in `type: pserv` + `plan: starter`.
- **`envVarGroups`**: `JWT_SECRET_KEY` sta nel gruppo `jinbocho-jwt` condiviso → lo inserisci una volta e auth/catalog/gateway lo ereditano identico (requisito critico per la validazione JWT).
