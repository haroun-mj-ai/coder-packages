# QA runbook — testing what autopilot built

How to take one `ready-to-test` issue from "PRs are open" to "merged", including
the changed-vs-baseline comparison and the e2e suite.

## The shape of an issue

One Linear issue is **two or three PRs in three different repos**, not one:

| repo | what its PR carries |
|---|---|
| `JourneyAI-Team/journeyai-backend` | the backend code |
| `JourneyAI-Team/frontend` | the frontend code |
| `JourneyAI-Team/root-for-local` | the plan doc, runbooks, and any e2e spec |

The root PR is usually **docs only** — do not mistake it for the change. Find
all of them by branch name:

```bash
for r in journeyai-backend frontend root-for-local; do
  gh pr list -R JourneyAI-Team/$r --json number,headRefName \
    --jq ".[]|select(.headRefName|test(\"eng-<ID>\"))|\"$r #\(.number)\""
done
```

Current mapping (2026-08-13):

| issue | backend | frontend | root | worktrees |
|---|---|---|---|---|
| ENG-1199 | #628 | — | #154 | `wt-eng1199-{be,root}` |
| ENG-1135 | #629 | #390 | #155 | `wt-eng1135-{be,fe,root}` |
| ENG-1138 | #630 | — | #156 | `wt-eng1138-{be,fe,root}` |
| ENG-1140 | #624 | — | #153 | `wt-eng1140-{be,root}` |
| ENG-1137 | #631 | — | #157 | `wt-eng1137-{be,fe,root}` |
| ENG-1181 | — | #388 | #152 | `wt-eng1181-{be,fe,root}` |

## Step 0 — environment (once per shell)

These three facts are non-obvious and cost real money to rediscover:

```bash
# 1. native libs: without this `import numpy` dies (libz), taking the whole
#    backend with it. ap-env.sh discovers and exports them.
source /home/coder/coder-packages/autopilot/bin/ap-env.sh

# 2. the env file must be EXPORTED (OPENAI_API_KEY is read from the raw
#    environment, not from pydantic settings). It must also be LF, not CRLF.
cd /home/coder/root-for-local/backend && set -a && . ./.env.local && set +a

# 3. the databases are NOT on localhost — the docker daemon is the host's, so
#    published ports live behind the bridge. .env.local already points at:
#      mongo  host.docker.internal:27018   (27017 is a DIFFERENT, EMPTY stack)
#      redis  host.docker.internal:6380
```

## Step 1 — bring up the pair you are comparing

The point is a **side-by-side**: the same screen on unchanged `dev` and on the
change, so a difference is attributable. Baseline stays on 5173/8000; the change
gets its own ports.

```bash
# BASELINE (unchanged dev) — usually already running; check first
ss -ltn | grep -E ':(5173|8000)'
cd /home/coder/root-for-local/frontend && npx vite --port 5173 --strictPort &
cd /home/coder/root-for-local/backend  && poetry run uvicorn app.main:app --port 8000 &

# CHANGED (this issue's worktrees). Ports by convention: fe 5174+, be 8001+.
cd /home/coder/root-for-local/wt-eng<ID>-fe
ln -s ../frontend/node_modules node_modules      # no second npm install
npx vite --port 5175 --strictPort &

cd /home/coder/root-for-local/wt-eng<ID>-be
cp ../backend/.env.local .env.local              # worktrees have no env file
poetry run uvicorn app.main:app --port 8002 &
```

**CORS:** the backend admits only 5173-5176 by default
(`_DEFAULT_CORS_ORIGINS`, `backend/app/main.py`). A frontend on any other port
gets a broken page that looks like a bug in the change. Either stay inside that
range, or set `BACKEND_CORS_ORIGINS` for the backend you start.

**Backend-only issues** (1199, 1138, 1140, 1137) need no frontend at all —
compare via the API (step 2b).

## Step 2 — exercise it

### 2a. UI issues (1135, 1181)

Open both in your browser through the Coder port forward, side by side:

- baseline `http://localhost:5173`
- change   `http://localhost:5175`

Log in with your own account, then walk the ticket's actual user path — not a
smoke test. For each, confirm the change appears on the changed port and does
**not** on the baseline, then check the neighbours the plan's *Interaction
surface* section names (that section exists precisely so you know what else to
click).

### 2b. Backend-only issues

```bash
# get a token (the endpoint is FORM-encoded, OAuth2 style — JSON gets a 422)
curl -s -X POST http://localhost:8002/api/v1/auth/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'username=<you@meetjourney.ai>' \
  --data-urlencode 'password=<password>'

# then hit the same endpoint on 8000 (baseline) and 8002 (change) and diff
```

## Step 3 — the e2e suite

```bash
cd /home/coder/root-for-local/tests/e2e
npx playwright test tests/cockpit/<spec>.spec.ts --project=chromium
```

**Blocked today, two reasons** — fix these once and the suite works forever:

1. **Chromium cannot start.** The browser is downloaded but 20 system libraries
   are missing (`libX11`, `libatk`, `libcairo`, `libcups`, `libasound`, …).
   `npx playwright install-deps` needs apt, which this box does not have; the
   nix route is `nix profile install nixpkgs#playwright-driver.browsers` plus
   `PLAYWRIGHT_BROWSERS_PATH` pointing at it.
2. **No login the suite can use.** 26 users exist in the 27018 database but none
   has a password we know (hashes came from the migrated environment), and
   registration is invite-only so `global-setup.ts` cannot bootstrap one. Seed a
   known password for `e2e-test@meetjourney.ai` using the backend's own hashing
   function, then put it in `tests/e2e/.env.e2e` (already written, with the
   correct hosts).

Until then, e2e specs are committed and compile-checked but never executed —
which is exactly what the "needs a human" sections in the PRs have been saying.

## Step 4 — merge

```bash
/ship-work <plan path>
```

It rebases, waits for CI, merges in dependency order (backend before frontend
when the frontend consumes a new field), moves Linear to `Staging`, and archives
the plan. Merge the **code** PRs; the root doc PR rides along in the same run.

Afterwards, close the inbox issue — the pipeline does not close it for you, and
the daily brief keeps listing it until you do.

## Order of work when several are ready

1. Anything `needs-input` first — it is blocked on a decision only you can make,
   and every cycle it waits is a slot doing nothing for it.
2. Backend-only issues next — no servers to start, just curl.
3. UI issues last — they need the side-by-side and the most attention.
