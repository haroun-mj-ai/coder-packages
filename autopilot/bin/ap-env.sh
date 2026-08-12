#!/usr/bin/env bash
# shellcheck shell=bash
# Sourceable env setup for autopilot scripts. Not executed directly.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/ap-env.sh"
#
# Derives GITHUB_PERSONAL_ACCESS_TOKEN (headless shells skip ~/.bashrc's
# derivation), sources user config from ~/.autopilot/env if present, then
# fills in defaults for anything still unset.

# GitHub token: only derive if the caller (or a stub PATH in tests) hasn't
# already set one.
if [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token 2>/dev/null || true)"
  export GITHUB_PERSONAL_ACCESS_TOKEN
fi

export AP_HOME="${AP_HOME:-$HOME/.autopilot}"

# User config: NTFY_TOPIC, SLACK_WEBHOOK_URL, AP_MAX_ISSUES_PER_DAY,
# AP_MAX_DAY_COST_USD, AP_TZ, AP_INBOX_REPO, AP_FULL_POLL_INTERVAL_MIN. Never
# overwritten by defaults below if already set here.
if [[ -f "$AP_HOME/env" ]]; then
  # shellcheck disable=SC1091
  source "$AP_HOME/env"
fi

export NTFY_TOPIC="${NTFY_TOPIC:-}"
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
export AP_MAX_ISSUES_PER_DAY="${AP_MAX_ISSUES_PER_DAY:-3}"
export AP_MAX_DAY_COST_USD="${AP_MAX_DAY_COST_USD:-50}"
export AP_TZ="${AP_TZ:-UTC}"
export AP_INBOX_REPO="${AP_INBOX_REPO:-haroun-mj-ai/autopilot-inbox}"
# Minutes between the pre-scan gate's fallback full poll -- pure insurance
# against (a) a human inbox comment misclassified as agent-authored by the
# `Plan file:` / `Phase:` marker heuristic, and (b) a claim stranded by a
# mid-cycle crash that the poll skill's own stale-claim sweep would recover.
# Not a queue-pickup mechanism (intake is fully deterministic via the inbox
# legs). 0 disables this leg entirely.
export AP_FULL_POLL_INTERVAL_MIN="${AP_FULL_POLL_INTERVAL_MIN:-360}"

# Global auto-approve: 1 = build every plan-review issue as soon as it lands,
# without waiting for a "go" comment. Never applies to needs-input (a
# blocking question always waits for the owner). Two other switches
# auto-approve a single delegation without this global flag: the `auto`
# label on the inbox issue, or an owner comment whose first line is exactly
# `auto`. See autopilot-protocol.md's inbox contract.
export AP_AUTO_APPROVE="${AP_AUTO_APPROVE:-0}"

# Marker inherited by every claude process autopilot spawns; the user's
# global Stop hook checks it to avoid phone-pinging on headless cycles.
export AP_AUTOPILOT=1

# Build lane concurrency: N implement->ship chains can run at once instead of
# one. Safe to parallelize because of two properties of THIS repo, not a
# general guarantee: backend tests run on mongomock (in-memory, created fresh
# per test), so concurrent `pytest` runs never share a database; and every
# build works in its own git worktree, so concurrent implementers never touch
# the same checkout. Clamped to 1..4 -- each slot gets its own frontend/
# backend port pair (see ap-cycle.sh), and the CORS allowlist plus this
# workspace's realistic resource budget both cap out well before higher N
# would help.
export AP_BUILD_SLOTS="${AP_BUILD_SLOTS:-2}"
if ! [[ "$AP_BUILD_SLOTS" =~ ^[0-9]+$ ]]; then
  AP_BUILD_SLOTS=2
elif [[ "$AP_BUILD_SLOTS" -lt 1 ]]; then
  AP_BUILD_SLOTS=1
elif [[ "$AP_BUILD_SLOTS" -gt 4 ]]; then
  AP_BUILD_SLOTS=4
fi
export AP_BUILD_SLOTS

# Ship lane concurrency: N standalone ship-only retries (see ap-cycle.sh's
# action=ship arm) can run at once, capped HIGHER than the build lane
# specifically because a ship act is almost pure waiting on GitHub CI -- it
# starts no dev servers and barely touches the machine, so many can be in
# flight with negligible added load. Clamped to 1..6. The implement->ship
# CHAIN inside one cycle does NOT use this lane -- it keeps the build slot it
# already holds for the whole chain (see ap-cycle.sh's comment at the
# implement action for why).
export AP_SHIP_SLOTS="${AP_SHIP_SLOTS:-3}"
if ! [[ "$AP_SHIP_SLOTS" =~ ^[0-9]+$ ]]; then
  AP_SHIP_SLOTS=3
elif [[ "$AP_SHIP_SLOTS" -lt 1 ]]; then
  AP_SHIP_SLOTS=1
elif [[ "$AP_SHIP_SLOTS" -gt 6 ]]; then
  AP_SHIP_SLOTS=6
fi
export AP_SHIP_SLOTS

# Minutes the pipeline stays auto-paused after a usage-limit failure before
# clearing itself (see ap-cycle.sh's pause-reason handling). A real-bug pause
# (reason "failures") or a manual pause (reason "manual") never auto-clears,
# regardless of this value. 0 disables auto-resume entirely -- every pause
# then waits for a human, same as before this feature existed.
export AP_LIMIT_COOLDOWN_MIN="${AP_LIMIT_COOLDOWN_MIN:-60}"

# Native-extension libraries this workspace does not have on the default loader
# path. Without them `import numpy` dies with "libz.so.1: cannot open shared
# object file", which cascades through qdrant_client -> grpc and makes the whole
# backend unimportable: no pytest, no local API, no e2e. Two separate autopilot
# runs each burned ~$5 rediscovering this and both misdiagnosed it as libstdc++.
# Exported here so every act inherits it.
_AP_ZLIB="$(echo /nix/store/*zlib*/lib | tr ' ' '\n' | while read -r d; do [ -e "$d/libz.so.1" ] && { echo "$d"; break; }; done)"
_AP_GCCLIB="$(echo /nix/store/*gcc*-lib/lib | tr ' ' '\n' | while read -r d; do [ -e "$d/libstdc++.so.6" ] && { echo "$d"; break; }; done)"
if [[ -n "${_AP_ZLIB:-}" || -n "${_AP_GCCLIB:-}" ]]; then
  export LD_LIBRARY_PATH="${_AP_ZLIB:+$_AP_ZLIB:}${_AP_GCCLIB:+$_AP_GCCLIB:}${LD_LIBRARY_PATH:-}"
fi
unset _AP_ZLIB _AP_GCCLIB
