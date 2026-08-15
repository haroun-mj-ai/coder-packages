#!/usr/bin/env bash
# Personal tool (haroun-only, not part of the JourneyAI repo): launch an
# isolated backend instance for a concurrent e2e/manual-QA run, so N
# tickets/worktrees can each run the cockpit e2e suite at the same time
# without colliding on ports or CORS.
#
# Usage:
#   run-e2e-backend.sh <backend-dir> <port> <frontend-origin>
#
# Example:
#   run-e2e-backend.sh /home/coder/root-for-local/backend 8010 http://localhost:5177
#     -> backend listens on 0.0.0.0:8010, CORS allows http://localhost:5177
#
# <backend-dir> is any JourneyAI backend checkout/worktree with its own
# .env.local (from `make setup-local`) — the main checkout, or a per-ticket
# backend/ worktree if the plan touches backend code.
#
# Pick any free port — check first with `ss -ltn`. Never reuse the human's
# own baseline port (conventionally 8000).
#
# NOTE — the real underlying constraint this works around: every e2e mock
# route matcher (tests/e2e/lib/cockpit-helpers.ts, explore-mocks.ts,
# manager-cockpit-mocks.ts, and ~65 spec files) hardcodes
# `url.port === "8000"`. That means a concurrent backend on any OTHER port
# satisfies real (non-mocked) API calls fine, but Playwright's own route
# mocks won't intercept — so *manual* browser QA against a second port works
# perfectly, but the *automated* Playwright suite still needs the app's own
# backend on port 8000 specifically to have its mocks fire. See
# mock-port.ts.reference in this same directory for a verified (but
# deliberately unpushed — kept personal, per Haroun's call 2026-08-15) fix:
# a single exported constant + a mechanical find/replace across those ~68
# files, parameterized by an E2E_MOCK_API_PORT env var, defaulting to "8000"
# for zero behavior change anywhere it isn't set.
#
# Three env-loading gotchas this script handles, each confirmed by direct
# testing against this workspace's actual poetry env (2026-08-14/15):
#
#   1. `.env.local`'s `ENVIRONMENT=local # local, development, production`
#      line carries an inline comment. uvicorn's --env-file loader has
#      tolerated this in practice, but stripping it is a one-line, zero-risk
#      safety net against a stricter parser in a future dependency bump.
#   2. `.env.local` has no trailing newline, so naively appending an
#      override line glues it onto the file's last line — concretely,
#      BACKEND_CORS_ORIGINS's JSON array gains "extra data" and
#      pydantic-settings refuses to boot. Force a newline boundary first.
#   3. LD_LIBRARY_PATH set *inside* an --env-file is NOT reliable here: it
#      updates os.environ from within the already-running Python process,
#      but grpc's compiled `_cython.cygrpc` extension is loaded via a
#      dlopen() that runs before that update lands (most likely because an
#      earlier import in the chain — e.g. numpy — already triggered glibc's
#      one-time LD_LIBRARY_PATH resolution for this process). Every uvicorn
#      launch backed only by --env-file failed with
#      `ImportError: libstdc++.so.6: cannot open shared object file`.
#      Passing it as a REAL argument to `poetry run env LD_LIBRARY_PATH=...`
#      instead — so it is present in the process environment at exec time,
#      before the interpreter even starts — fixed this every time it was
#      retested. Discovered dynamically here (glob over /nix/store) rather
#      than trusting `.env.local`'s own pinned store hash, which can go
#      stale across a nix rebuild independently of this script.
#
# BACKEND_CORS_ORIGINS **replaces** rather than extends the default
# allowlist (see app/main.py's `allow_origins=settings.BACKEND_CORS_ORIGINS
# or _DEFAULT_CORS_ORIGINS`), so this instance's origin override must be set
# even though `.env.local` already pins one (for whichever other ticket last
# edited it) — this script's own override always wins, since it comes after
# in the generated file.
set -euo pipefail

USAGE="usage: run-e2e-backend.sh <backend-dir> <port> <frontend-origin>"
BACKEND_DIR="${1:?$USAGE}"
PORT="${2:?$USAGE}"
FRONTEND_ORIGIN="${3:?$USAGE}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo "port must be numeric" >&2
  exit 1
fi

cd "$BACKEND_DIR"

if [ ! -f .env.local ]; then
  echo ".env.local not found — run 'make setup-local' first" >&2
  exit 1
fi

ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT

# Gotcha 1: strip ENVIRONMENT's inline comment.
sed -E 's/^(ENVIRONMENT=[^ #]*)[[:space:]]*#.*/\1/' .env.local > "$ENV_FILE"

# Gotcha 2: force a newline boundary before appending our own override.
echo >> "$ENV_FILE"
printf 'BACKEND_CORS_ORIGINS=["%s"]\n' "$FRONTEND_ORIGIN" >> "$ENV_FILE"

# Gotcha 3: discover native lib dirs fresh, don't trust a pinned hash.
ZLIB_DIR="$(compgen -G '/nix/store/*zlib*/lib' | while read -r d; do [ -e "$d/libz.so.1" ] && { echo "$d"; break; }; done || true)"
GCC_LIB_DIR="$(compgen -G '/nix/store/*gcc*-lib/lib' | while read -r d; do [ -e "$d/libstdc++.so.6" ] && { echo "$d"; break; }; done || true)"
LD_PATH="${ZLIB_DIR:+$ZLIB_DIR:}${GCC_LIB_DIR:+$GCC_LIB_DIR:}${LD_LIBRARY_PATH:-}"

echo "Starting backend on 0.0.0.0:${PORT} (CORS: ${FRONTEND_ORIGIN}) ..."
exec poetry run env LD_LIBRARY_PATH="$LD_PATH" \
  uvicorn app.main:app --host 0.0.0.0 --port "$PORT" --env-file "$ENV_FILE"
