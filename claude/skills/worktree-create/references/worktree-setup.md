# Worktree Setup — the general checklist

A git worktree shares the repository's object store and **tracked** files, but is otherwise a *fresh checkout*. It
is missing everything git does not track and everything that is machine-local state. To be genuinely ready to
develop, run, and validate in, a worktree needs the items below. The list is **project-agnostic** — detect the
specifics from the repo (see *Detecting the specifics*), never assume a stack.

## What a fresh worktree needs

1. **A branch off the right base.** Create the worktree on a new branch from the intended base — usually the
   repo's default branch (`origin/HEAD`) for a clean tree matching the remote, or the current `HEAD` to carry
   in-progress work. Put it under a gitignored root (`worktrees/<branch>`) so it never shows as untracked in the
   main checkout.

2. **Gitignored config & secrets — the commonly-missed layer.** A fresh checkout has NONE of the untracked files
   the app reads at runtime: `.env`, `.env.local`, `.env.<stage>`, credential/service-account JSON, `*.pem` and
   other keys, `.npmrc` / `.pypirc`, local settings (`.claude/settings.local.json`), and anything similar. Copy
   these from the main working tree into the worktree. Confirm each is actually ignored (`git check-ignore <f>`)
   so tracked files are never duplicated. If the repo ships a `.worktreeinclude`, use that list as the source of
   truth for what to copy.

3. **Dependencies.** Install with the project's own package manager, detected from the manifests/lockfiles
   present. A monorepo needs an install per package (e.g. a backend and a frontend). Install *into* the worktree
   so its environment is isolated from the main checkout.

4. **Language runtime & an isolated environment.** Use the runtime version the project pins (`.python-version`,
   `.nvmrc`, `.tool-versions`, the `go`/`node` field in the manifest). Create the virtualenv / `node_modules`
   *inside* the worktree — never share the main checkout's — so versions can diverge per branch.

5. **Generated or downloaded artifacts install won't produce.** If the app needs codegen (protobuf, GraphQL, ORM
   clients), compiled assets, or downloaded models/caches to boot, run the project's generate/build step. Skip if
   there is none.

6. **Isolation for concurrent runs.** Only if you will actually *run* services in several worktrees at once: give
   each worktree a distinct **port** per long-running service so they don't collide, and where the app writes to a
   shared local database, a separate **database or schema** (or a disposable containerized DB) per worktree. If
   you are only building and testing, not serving, skip this.

7. **Verification — a detected health check.** Prove the worktree works before handing it off. Use the cheapest
   meaningful check the project supports, in order: start the app and hit its health endpoint if it exposes one →
   else a fast build / typecheck / test-collection smoke → else at minimum confirm dependencies resolved and the
   app imports/builds. Detect the command; do not assume one.

8. **Registration & later cleanup.** The worktree is now tracked (`git worktree list`). Know it exists so it can be
   removed (`git worktree remove <path>`) once its branch is merged, so stale worktrees don't pile up.

## Detecting the specifics (per repo, not assumed)

- **Install command** — from the lockfile/manifest present: `uv.lock`/`pyproject.toml` → `uv sync`; `poetry.lock`
  → `poetry install`; `requirements.txt` → `pip install -r requirements.txt`; `package-lock.json` → `npm ci`;
  `pnpm-lock.yaml` → `pnpm install`; `yarn.lock` → `yarn`; `bun.lockb` → `bun install`; `Cargo.toml` →
  `cargo build`; `go.mod` → `go mod download`; `Gemfile` → `bundle install`; `composer.json` → `composer install`.
  Several present → monorepo; install each in its own package dir.
- **Env/config files to copy** — intersect the repo's ignored, untracked files with common secret/config patterns:
  `git ls-files --others --ignored --exclude-standard` filtered to `.env*`, `*.local`, key/credential files. Or
  read `.worktreeinclude` if present. Check subdirectories too (e.g. `backend/.env`, `app/.env`).
- **Run command + port** — check the README, the manifest's scripts (`package.json` `scripts`, `pyproject` entry
  points), a `Procfile`, `docker-compose.yml`, or a `Makefile`; read a `PORT` / `*_PORT` from env or config.
- **Health endpoint** — grep the code/README for a health route (`/health`, `/api/health`, `/healthz`, `/ping`) or
  a `healthcheck` in `docker-compose.yml`. None → fall back to the build/test smoke.
- **Validation commands** — prefer **what CI already runs**: read `.github/workflows/*`, a `Makefile`, or the
  manifest's test/lint scripts and reuse those exact commands (test runner, type checker, linter). CI is the
  project's own source of truth for "what proves this code works" — don't invent `pytest`/`mypy` if the repo uses
  something else.

> **Detect, don't hardcode** — everything above is discovered from the target repo at runtime.

## This project's specifics (skip detection for these — already known)

- **`backend/`**: install with `poetry install`. `import numpy`/`qdrant_client` fails with `libz.so.1` missing
  unless `LD_LIBRARY_PATH` is exported — see `autopilot/bin/ap-env.sh` for the discovered paths. `.env.local` must
  be LF, not CRLF, and is exported with `set -a; . ./.env.local; set +a` (not just sourced) since
  `OPENAI_API_KEY` etc. are read from the raw environment. Health/smoke: `poetry run pytest <path> -q --no-cov` —
  an unscoped run trips the repo-wide coverage gate.
- **`frontend/`**: install with `npm install`; symlink `node_modules` from the main checkout rather than
  reinstalling if disk/time matters: `ln -s ../frontend/node_modules node_modules`. A worktree's dev server
  **must** bind a port in **5173-5176** (`backend/app/main.py`'s `_DEFAULT_CORS_ORIGINS`) — anything outside that
  range 404s against the backend and looks like a broken change, not a port problem: `npx vite --port 5175 --strictPort`.
- **Never run `npx playwright install`** in this workspace — it silently overwrites the shared, workspace-wide
  Chromium for every concurrent session and can't be repaired headlessly.
- **Base branch per repo**: root/`backend/`/`frontend/` → `dev`; `assistants/`/`observability/` → `main` (no
  `dev` branch there).
