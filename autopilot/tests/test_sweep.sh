#!/usr/bin/env bash
# Self-contained test harness for ap-sweep.sh. No network: builds a throwaway
# "origin" bare repo plus a "root" clone standing in for AP_WORK_REPO, with
# three wt-eng* worktrees:
#   - merged + clean   -> eligible for removal
#   - unmerged         -> refused, kept
#   - merged but dirty -> refused, kept
# Asserts dry-run reports all three correctly and changes nothing, and that
# --yes removes ONLY the merged+clean one, leaving the other two untouched.
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
SWEEP="$BIN_DIR/ap-sweep.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

assert() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# =============================================================================
# Fixture: one bare "origin", one local clone acting as AP_WORK_REPO (the
# root repo), with three wt-eng* worktrees off it. backend/frontend/
# assistants/observability siblings are left absent -- ap-sweep.sh must
# skip repos that don't exist rather than erroring.
# =============================================================================
setup_fixture() {
  CASE_AP_HOME="$(mktemp -d)"
  ORIGIN="$(mktemp -d)"
  ROOT="$(mktemp -d)"

  git init -q --bare "$ORIGIN"

  git init -q "$ROOT"
  git -C "$ROOT" config user.email t@t.com
  git -C "$ROOT" config user.name t
  git -C "$ROOT" checkout -q -b dev
  echo one >"$ROOT/f.txt"
  git -C "$ROOT" add f.txt
  git -C "$ROOT" commit -q -m "initial"
  git -C "$ROOT" remote add origin "$ORIGIN"
  git -C "$ROOT" push -q origin dev
  git -C "$ROOT" branch -q --set-upstream-to=origin/dev dev

  # merged + clean: branch fully merged into origin/dev, worktree untouched.
  git -C "$ROOT" branch merged-clean dev
  git -C "$ROOT" worktree add -q "$ROOT-wt/wt-eng9001-root" merged-clean >/dev/null

  # unmerged: branch has a commit dev/origin never got.
  git -C "$ROOT" branch unmerged dev
  git -C "$ROOT" worktree add -q "$ROOT-wt/wt-eng9002-root" unmerged >/dev/null
  echo two >"$ROOT-wt/wt-eng9002-root/g.txt"
  git -C "$ROOT-wt/wt-eng9002-root" add g.txt
  git -C "$ROOT-wt/wt-eng9002-root" commit -q -m "unmerged work"

  # merged but dirty: branch merged, worktree has an uncommitted change.
  git -C "$ROOT" branch merged-dirty dev
  git -C "$ROOT" worktree add -q "$ROOT-wt/wt-eng9003-root" merged-dirty >/dev/null
  echo scratch >"$ROOT-wt/wt-eng9003-root/scratch.txt"

  mkdir -p "$CASE_AP_HOME/logs"
}

teardown_fixture() {
  rm -rf "$CASE_AP_HOME" "$ORIGIN" "$ROOT" "$ROOT-wt" 2>/dev/null || true
}

run_sweep() {
  AP_HOME="$CASE_AP_HOME" AP_WORK_REPO="$ROOT" bash "$SWEEP" "$@"
}

# =============================================================================
# Case A: dry-run (default, no args) reports all three correctly and changes
# nothing on disk.
# =============================================================================
setup_fixture
out_a="$(run_sweep 2>&1)"
rc_a=$?

assert "case_a: exit 0" [ "$rc_a" -eq 0 ]
assert "case_a: merged+clean reported KEPT (dry-run, would remove)" bash -c \
  "echo '$out_a' | grep 'wt-eng9001-root' | grep -q 'KEPT (dry-run)'"
assert "case_a: unmerged reported REFUSED - not merged" bash -c \
  "echo '$out_a' | grep 'wt-eng9002-root' | grep -q 'REFUSED - not merged'"
assert "case_a: merged-dirty reported REFUSED - uncommitted" bash -c \
  "echo '$out_a' | grep 'wt-eng9003-root' | grep -q 'REFUSED.*uncommitted'"
assert "case_a: merged+clean worktree still present after dry-run" \
  [ -d "$ROOT-wt/wt-eng9001-root" ]
assert "case_a: merged+clean branch still present after dry-run" bash -c \
  "git -C '$ROOT' branch --list merged-clean | grep -q merged-clean"
assert "case_a: unmerged worktree untouched" [ -d "$ROOT-wt/wt-eng9002-root" ]
assert "case_a: merged-dirty worktree untouched" [ -d "$ROOT-wt/wt-eng9003-root" ]
assert "case_a: summary line says nothing removed" bash -c \
  "echo '$out_a' | grep -q 'dry-run: 1 would be removed, 2 refused'"
teardown_fixture

# =============================================================================
# Case B: --dry-run explicit behaves identically to no-args.
# =============================================================================
setup_fixture
out_b="$(run_sweep --dry-run 2>&1)"
assert "case_b: --dry-run explicit also reports KEPT for the eligible one" bash -c \
  "echo '$out_b' | grep 'wt-eng9001-root' | grep -q 'KEPT (dry-run)'"
assert "case_b: --dry-run explicit changes nothing" [ -d "$ROOT-wt/wt-eng9001-root" ]
teardown_fixture

# =============================================================================
# Case C: --yes removes ONLY the merged+clean worktree and its branch; the
# unmerged and dirty ones are refused and left exactly as they were.
# =============================================================================
setup_fixture
out_c="$(run_sweep --yes 2>&1)"
rc_c=$?

assert "case_c: exit 0" [ "$rc_c" -eq 0 ]
assert "case_c: merged+clean reported REMOVED" bash -c \
  "echo '$out_c' | grep 'wt-eng9001-root' | grep -q 'REMOVED'"
assert "case_c: merged+clean worktree gone" [ ! -d "$ROOT-wt/wt-eng9001-root" ]
assert "case_c: merged+clean branch deleted" bash -c \
  "! git -C '$ROOT' branch --list merged-clean | grep -q merged-clean"

assert "case_c: unmerged still reported REFUSED - not merged" bash -c \
  "echo '$out_c' | grep 'wt-eng9002-root' | grep -q 'REFUSED - not merged'"
assert "case_c: unmerged worktree NOT removed" [ -d "$ROOT-wt/wt-eng9002-root" ]
assert "case_c: unmerged branch NOT deleted" bash -c \
  "git -C '$ROOT' branch --list unmerged | grep -q unmerged"

assert "case_c: merged-dirty still reported REFUSED - uncommitted" bash -c \
  "echo '$out_c' | grep 'wt-eng9003-root' | grep -q 'REFUSED.*uncommitted'"
assert "case_c: merged-dirty worktree NOT removed" [ -d "$ROOT-wt/wt-eng9003-root" ]
assert "case_c: merged-dirty branch NOT deleted" bash -c \
  "git -C '$ROOT' branch --list merged-dirty | grep -q merged-dirty"
assert "case_c: merged-dirty scratch file still present (never touched)" \
  [ -f "$ROOT-wt/wt-eng9003-root/scratch.txt" ]

assert "case_c: summary line says 1 removed, 2 refused" bash -c \
  "echo '$out_c' | grep -q '^1 removed, 2 refused$'"
teardown_fixture

# =============================================================================
# Case D: never --force, never branch -D -- an unmerged branch's worktree
# survives even a --yes run untouched (already covered above), and the
# sweep never invokes `worktree remove --force` or `branch -D` at all.
# =============================================================================
setup_fixture
run_sweep --yes >/dev/null 2>&1
assert "case_d: sweep script never invokes 'worktree remove --force'" bash -c \
  "! grep -E 'git .*worktree remove.*--force' '$SWEEP'"
assert "case_d: sweep script never invokes 'branch -D'" bash -c \
  "! grep -E 'git .*branch -D' '$SWEEP'"
teardown_fixture

# =============================================================================
# Case E: an unknown flag is rejected rather than silently treated as a
# dry-run or a --yes.
# =============================================================================
setup_fixture
run_sweep --bogus >/dev/null 2>&1
rc_e=$?
assert "case_e: unknown flag exits non-zero" [ "$rc_e" -ne 0 ]
teardown_fixture

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
