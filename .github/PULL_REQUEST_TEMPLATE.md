## What & why

<!-- What does this change and what problem does it solve? Link the issue: Closes #123 -->

## How

<!-- Brief notes on the approach, anything reviewers should look at first. -->

## Checklist

- [ ] Tests added/updated and passing
- [ ] `ruff check` + `mypy --strict` green (backend) or `npm run typecheck` + `npm run test` (frontend)
- [ ] No secrets committed
- [ ] Docs / `types/api.ts` updated if the API contract changed
- [ ] Endpoints route through use cases (no direct repository calls)
