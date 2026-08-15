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
# AP_MAX_DAY_COST_USD, AP_TZ. Never overwritten by defaults below if already
# set here.
if [[ -f "$AP_HOME/env" ]]; then
  # shellcheck disable=SC1091
  source "$AP_HOME/env"
fi

export NTFY_TOPIC="${NTFY_TOPIC:-}"
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
export AP_MAX_ISSUES_PER_DAY="${AP_MAX_ISSUES_PER_DAY:-3}"
export AP_MAX_DAY_COST_USD="${AP_MAX_DAY_COST_USD:-50}"

# Informational only (not enforced -- `ap status` reports against it, nothing
# auto-pauses on it). The account's weekly Claude usage pool is shared between
# this pipeline and interactive Claude Code sessions, so this is the
# pipeline's own carved-out SHARE of that pool, not the whole thing -- leave
# headroom for interactive use and estimate error. Default assumes a Max 5x
# plan (~$523/week API-equivalent per Anthropic's own estimate) with ~60% of
# that going to the pipeline. Both the ledger's `cost` field (see append_ledger
# in ap-cycle.sh) and this figure are Claude Code's own `total_cost_usd` --
# same basis as the $523 estimate, so they're directly comparable.
export AP_MAX_WEEK_COST_USD="${AP_MAX_WEEK_COST_USD:-310}"
export AP_TZ="${AP_TZ:-UTC}"

# Global auto-approve: 1 = build every plan-review ticket as soon as it lands,
# without waiting for `ap approve`. Never applies to needs-input (a blocking
# question always waits for the owner). A per-ticket auto-approve switch
# (`ap approve --auto`, or `ap queue --auto` at intake time) works the same
# way for a single ticket without this global flag. See
# autopilot-protocol.md's local queue contract.
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

# How ap-cycle.sh launches and reconciles an act. "persistent" (default): each
# act runs as a real `claude` session in its own tmux window inside the
# `autopilot` session, so a NEEDS_HUMAN stop parks alive (releasing its lane
# slot) instead of exiting -- `tmux attach -t autopilot` and typing into the
# window, or a GitHub inbox reply, both resume it in place. "oneshot" restores
# today's exact behavior: `claude -p`, no tmux window, the process exits on
# any terminal state including NEEDS_HUMAN, and a later reply starts a fresh
# invocation from the plan file (kata) instead of resuming a live session.
# This is a launch-mechanism choice only -- it never changes what prompt text
# or flags an act is invoked with.
export AP_ACT_LAUNCH_MODE="${AP_ACT_LAUNCH_MODE:-persistent}"
if [[ "$AP_ACT_LAUNCH_MODE" != "persistent" && "$AP_ACT_LAUNCH_MODE" != "oneshot" ]]; then
  AP_ACT_LAUNCH_MODE=persistent
fi
export AP_ACT_LAUNCH_MODE

# The tmux session persistent-mode acts (and supercronic itself) live in.
# Overridable so the test suite can point it at a throwaway session name
# instead of ever touching the real one.
export AP_TMUX_SESSION="${AP_TMUX_SESSION:-autopilot}"

# Native-extension libraries this workspace does not have on the default loader
# path. Without them `import numpy` dies with "libz.so.1: cannot open shared
# object file", which cascades through qdrant_client -> grpc and makes the whole
# backend unimportable: no pytest, no local API, no e2e. Two separate autopilot
# runs each burned ~$5 rediscovering this and both misdiagnosed it as libstdc++.
# Exported here so every act inherits it.
#
# NOT the primary fix as of 2026-08-13: LD_LIBRARY_PATH doesn't reliably
# survive every invocation path (cron/tmux/headless-claude/fresh-worktree), and
# nix's own ld.so ignores it in some of those anyway. The real fix is
# journey/backend/scripts/fix-nix-native-libs.sh, run by `make setup-local`
# after every `poetry install` -- see the backend-pytest-workspace-limits
# memory. This export is left in as harmless defense-in-depth, not the fix.
_AP_ZLIB="$(echo /nix/store/*zlib*/lib | tr ' ' '\n' | while read -r d; do [ -e "$d/libz.so.1" ] && { echo "$d"; break; }; done)"
_AP_GCCLIB="$(echo /nix/store/*gcc*-lib/lib | tr ' ' '\n' | while read -r d; do [ -e "$d/libstdc++.so.6" ] && { echo "$d"; break; }; done)"
if [[ -n "${_AP_ZLIB:-}" || -n "${_AP_GCCLIB:-}" ]]; then
  export LD_LIBRARY_PATH="${_AP_ZLIB:+$_AP_ZLIB:}${_AP_GCCLIB:+$_AP_GCCLIB:}${LD_LIBRARY_PATH:-}"
fi
unset _AP_ZLIB _AP_GCCLIB

# Playwright: the browsers Playwright downloads itself are Ubuntu-built and
# cannot run here (20 missing system libs; lending them nix libs makes them
# crash with "stack smashing detected" instead -- a glibc mismatch). The nix
# playwright-driver.browsers build DOES run, so ~/.local/share/pw-browsers
# holds symlinks from the revision names this Playwright expects to the nix
# ones. Without this, every browser QA attempt fails and the agent wastes the
# run rediscovering it.
if [[ -d "$HOME/.local/share/pw-browsers" ]]; then
  export PLAYWRIGHT_BROWSERS_PATH="$HOME/.local/share/pw-browsers"
fi

# Playwright must use FULL chrome, not chrome-headless-shell. The headless
# shell launches but its renderer dies the moment it paints the real app
# ("Target page, context or browser has been closed" right after a successful
# goto); full chrome renders it fine. Playwright picks the shell by default for
# headless chromium, so point it at the full binary explicitly.
_AP_PW_CHROME="$(echo "$HOME"/.local/share/pw-browsers/chromium-*/chrome-linux64/chrome 2>/dev/null | tr ' ' '\n' | head -1)"
if [[ -x "${_AP_PW_CHROME:-}" ]]; then
  export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="$_AP_PW_CHROME"
fi
unset _AP_PW_CHROME
