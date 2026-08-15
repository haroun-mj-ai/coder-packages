# JourneyAI concurrent e2e setup (personal, not part of the repo)

Built 2026-08-15 while verifying ENG-1316. Kept here rather than in
`root-for-local`/`backend` deliberately — Haroun's call, personal workflow
tooling, not a shared-repo change.

## The problem

Every e2e mock route matcher in `tests/e2e/lib/cockpit-helpers.ts`,
`explore-mocks.ts`, `manager-cockpit-mocks.ts`, and ~65 spec files hardcodes
`url.port === "8000"`. Playwright's `page.route()` only intercepts a request
if the port matches, so:

- The app's *real* (non-mocked) calls — workspace, organization, auth, ws
  ticket — need an actually-running backend, on whatever port the frontend's
  `VITE_BASE_URL` points at.
- The *mocked* calls (action-item list, quick-filters, team-membership,
  persona, etc.) only get intercepted if that same port is literally `8000`.

Two consequences:
- **Manual browser QA** against a concurrent backend on any free port works
  fine — nothing about it depends on port 8000.
- **The automated Playwright suite** (any spec using these helpers) only
  fires its mocks against a backend on port 8000 specifically. A concurrent
  ticket's backend on a different port will 200 on real endpoints but never
  get its mocked rows/lists back — the app will genuinely try to hit that
  wrong path and mocks silently won't fire.

A shared baseline backend conventionally binds `0.0.0.0:8000` (wildcard) —
confirmed you cannot *also* bind a specific address (`127.0.0.2:8000`, etc.)
on that same port once a wildcard bind holds it: `[Errno 98] Address already
in use`. So there is no clever loopback-aliasing trick around this; the only
two real options are (a) parameterize the hardcoded port across the test
suite, or (b) accept that concurrent runs get manual QA but not the
automated suite until the app's own backend is free.

`mock-port.ts.reference` + `parameterize-mock-port.py.reference` in this
directory are a **verified, working fix** for (a) — a single exported
constant (`MOCK_API_PORT`, reads `process.env.E2E_MOCK_API_PORT`, defaults to
`"8000"` so it's a no-op everywhere it isn't set) plus a mechanical
find/replace that touched all 68 files cleanly (confirmed: zero remaining
hardcoded occurrences, correct import inserted in every file, verified by
direct testing that the replacement compiles). **Not applied to the real
repo** — kept here as reference in case it's ever worth submitting upstream
through a real PR/review, not silently landed.

## What `run-e2e-backend.sh` actually solves

Independent of the port-matching problem above: getting *any* second backend
instance running at all, on any port, hit three real env-loading bugs in
this workspace (confirmed by direct, repeated testing 2026-08-14/15):

1. `.env.local`'s `ENVIRONMENT=local # local, development, production` line
   has an inline comment.
2. `.env.local` has no trailing newline — naively appending an override line
   glues onto its last line and corrupts it (concretely broke
   `BACKEND_CORS_ORIGINS`'s JSON parsing).
3. **The big one**: `LD_LIBRARY_PATH` set via uvicorn's `--env-file` does
   NOT reliably reach grpc's compiled extension — every attempt that relied
   on `--env-file` alone for this failed with `ImportError: libstdc++.so.6:
   cannot open shared object file`, even reusing an env file that had worked
   minutes earlier in the same session. Passing it as a real argument to
   `poetry run env LD_LIBRARY_PATH=... uvicorn ...` — present in the process
   environment at exec time, not injected from inside an already-running
   Python process — fixed it every time, no exceptions across ~5 repeated
   tests.

`run-e2e-backend.sh` handles all three, discovers the nix zlib/gcc-lib paths
fresh each run (not trusting `.env.local`'s own pinned store hash, which can
go stale independently of this script), and sets `BACKEND_CORS_ORIGINS` to
exactly the frontend origin you pass it (this setting *replaces* rather than
extends the app's default allowlist, so it must always be set explicitly,
even though `.env.local` usually already has some other ticket's value
pinned there).

## Usage

```bash
# Manual QA against a second, fully isolated backend — works today, no
# repo changes needed:
~/coder-packages/scripts/journeyai-e2e/run-e2e-backend.sh \
  /home/coder/root-for-local/backend 8010 http://localhost:5177

# Point that worktree's frontend .env at the same port:
#   VITE_BASE_URL=http://localhost:8010/api/v1
#   VITE_WS_URL=ws://localhost:8010
```

Check `ss -ltn` first and pick any free port. Never reuse the human's own
baseline (conventionally 8000).

For the **automated** Playwright suite to also work concurrently, you'd
additionally need to apply `mock-port.ts.reference` (copy it to
`tests/e2e/lib/mock-port.ts` in the target worktree, then run
`parameterize-mock-port.py.reference` pointed at that worktree's
`tests/e2e/` — edit the `ROOT` path at the top first) and set
`E2E_MOCK_API_PORT` in that worktree's `tests/e2e/.env.e2e` to match. Not
done automatically by anything — a deliberate, occasional manual step, not
part of the personal workflow by default.
