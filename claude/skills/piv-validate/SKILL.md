---
name: piv-validate
description: Runs this project's full validation suite — tests, type checks, and linting across every part of the stack — then reports overall health. Use before committing, before opening a PR, or after finishing a chunk of work to confirm zero regressions.
---

# Validate

Run every check this project has and report a single PASS/FAIL verdict.

Wired to this project's actual stack (4 sibling repos: root, `backend/` FastAPI+Beanie, `frontend/` React+Vite,
`assistants/`). Scope every command to the paths the ticket actually touched — a full unscoped run is slow and
isn't what catches real regressions here; the per-unit scoped runs below plus `piv-review-changes` carry that
weight. If a broader sweep is genuinely wanted, scope it to the touched top-level package, not a bare unscoped
invocation.

Run the checks in order. Keep going after a failure so the report covers everything, and capture the
output of any command that fails.

## 1. Backend — tests

```bash
cd backend
set -a; . ./.env.local; set +a          # OPENAI_API_KEY etc. are read from the raw environment — file must be LF
poetry run pytest <paths touched or exercising them> -q --no-cov   # unscoped run trips the repo-wide coverage gate
```

**Expected:** all tests pass. **Known noise, baseline against untouched `dev` before attributing either to this
change:** some endpoint tests fail in isolation with a pydantic `AttributeError: id` (Beanie never initialized);
~2 dozen `test_specs_phase3`/`phase4` failures under `assistants/` are template drift, already skipped in CI.
If `import numpy`/`qdrant_client` fails with `libz.so.1` missing, `LD_LIBRARY_PATH` isn't exported — see
`autopilot/bin/ap-env.sh` for the discovered paths.

## 2. Backend — lint

```bash
cd backend && poetry run ruff check <paths touched>
```

**Expected:** not blocking — match neighbours, add no new errors, don't mass-reformat.

## 3. Frontend — type check + build

```bash
cd frontend && npm run build     # tsc + vite build — always run after any frontend change
```

**Expected:** zero TypeScript errors.

## 4. Frontend — unit tests + lint

```bash
cd frontend && npm run test:run
cd frontend && npm run lint
```

**Expected:** all tests pass; lint clean.

## 5. E2E — only if `tests/e2e/**` specs changed

```bash
cd tests/e2e && npx playwright test <spec>   # or the full suite only if genuinely needed — it needs running services
```

Skip the full Playwright suite by default; scope to the one spec this ticket added/touched.

## 6. Optional — live smoke test via Playwright MCP

Only for `frontend/`-facing changes, or any backend change with no test coverage of the actual endpoint. Confirm
which branch the dev server actually serves before trusting what you see — a worktree change never appears at
`localhost:5173`/`:8000` (those always serve the **main checkout**) unless you start a second server pointed at
the worktree, on a port in **5173-5176** (`backend/app/main.py`'s `_DEFAULT_CORS_ORIGINS` — anything outside that
range 404s and looks like a bug in your change, not a port problem).

**Never run `npx playwright install`** — it silently overwrites the shared workspace-wide Chromium for every
concurrent session.

## 6. Summary report

Report each check with a ✅ or ❌, then an overall verdict:

- One line per check
- **Overall: PASS or FAIL**

For every ❌, include the failing command and the relevant output. Do not fix anything here —
this skill reports; fixing is a separate step.

## Notes

- Keep this skill fast. It runs before every commit; if a step gets slow, that is a signal to fix the
  slow step, not to drop it from the checker.
- A checker that cannot fail is worthless. Once your commands are wired in, break something on
  purpose and confirm this skill reports ❌.
