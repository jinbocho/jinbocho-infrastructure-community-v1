# Contributing to Jinbocho

Thanks for your interest in Jinbocho — a self-hosted home library manager that maps
where your books physically live. Contributions of all sizes are welcome: bug reports,
docs, translations, and code.

## Ways to contribute

- 🐛 **Report a bug** — open an issue with steps to reproduce.
- 💡 **Suggest a feature** — open a feature request; describe the problem, not just the solution.
- 🌍 **Translate** — the UI ships in EN/IT/ES/FR; new locales are very welcome.
- 📖 **Improve docs** — even fixing a typo helps.
- 👩‍💻 **Write code** — look for issues labelled `good first issue`.

## Project layout

Jinbocho's Community edition is split across repositories under the
[`jinbocho`](https://github.com/jinbocho) org:

| Repo | What it is |
|------|------------|
| `jinbocho-infrastructure-v1` | Docker Compose / Render orchestration (start here) |
| `jinbocho-api-gateway-v1` | Public API gateway (BFF) |
| `jinbocho-auth-v1` | Auth: families, users, JWT |
| `jinbocho-catalog-v1` | Books, locations, ISBN ingestion |
| `jinbocho-fe` | React 18 + TypeScript SPA |

## Local setup

```bash
git clone https://github.com/jinbocho/jinbocho-infrastructure-v1.git
cd jinbocho-infrastructure-v1
docker compose -f docker/docker-compose.community.local.yml up --build -d   # all backend services + databases
```

For a single backend service:

```bash
cd jinbocho-auth-v1
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --reload --port 8001
```

Frontend:

```bash
cd jinbocho-fe
npm install
npm run dev      # http://localhost:5173
```

## Before opening a pull request

Each backend service must stay green on:

```bash
ruff check app tests
mypy --strict app
pytest tests/ -v
```

Frontend:

```bash
npm run typecheck
npm run test
```

### Code conventions

- **Clean Architecture**: domain → application → infrastructure → API, kept decoupled. The domain layer has zero knowledge of HTTP or the database.
- **Use cases first**: endpoints route through a use-case class; no direct repository calls in endpoints.
- **No logic in `__init__.py`**: one class per file.
- **Type hints everywhere**; `mypy --strict` must pass.
- **Comments explain *why*, not *what*** — prefer clear names.

## Pull request checklist

- [ ] Linked to an issue (or clearly describes the change)
- [ ] Tests added/updated and passing
- [ ] `ruff`, `mypy --strict`, and tests green (or `typecheck` + `test` for FE)
- [ ] No secrets committed
- [ ] API contract changes reflected in `jinbocho-fe/src/types/api.ts` if applicable

## License

By contributing, you agree your contribution is licensed under the **Jinbocho
Source-Available License** (see [LICENSE](LICENSE)), the same license as this
Community edition repo. This project is the exclusive intellectual property of
Carmelo La Gamba. Contributions require explicit permission.
