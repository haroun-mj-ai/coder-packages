#!/usr/bin/env bash
# Tests for scripts/install-skills.sh. Runs the real installer against a fake
# skills source (a copy of the script inside a throwaway repo layout) and a
# throwaway `git init` checkout — never touches the real JourneyAI checkout.
set -uo pipefail

REAL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install-skills.sh"

FAILURES=0
assert() {
  local desc="$1"; shift
  if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILURES=$((FAILURES + 1)); fi
}

# setup -> sets PKG (fake coder-packages) and REPO (fake JourneyAI checkout)
setup() {
  PKG="$(mktemp -d)"; REPO="$(mktemp -d)"
  mkdir -p "$PKG/scripts" "$PKG/claude/skills/alpha" "$PKG/claude/skills/beta"
  cp "$REAL_SCRIPT" "$PKG/scripts/"
  echo a >"$PKG/claude/skills/alpha/SKILL.md"
  echo b >"$PKG/claude/skills/beta/SKILL.md"
  echo p >"$PKG/claude/skills/protocol.md"
  echo ignored >"$PKG/claude/skills/notes.txt"

  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name T
  mkdir -p "$REPO/.claude/skills/alpha"
  echo team-copy >"$REPO/.claude/skills/alpha/SKILL.md"
  git -C "$REPO" add . && git -C "$REPO" commit -qm init
}
run() { JOURNEY_ROOT="$REPO" bash "$PKG/scripts/install-skills.sh" "$@" >"$REPO/../log.$$" 2>&1; echo $?; }
linked() { [ -L "$REPO/.claude/skills/$1" ] && [ "$(readlink "$REPO/.claude/skills/$1")" = "$PKG/claude/skills/$1" ]; }
excluded() { grep -qxF ".claude/skills/$1" "$REPO/.git/info/exclude"; }

# --- A: fresh install links every dir + .md, nothing else -------------------
setup
assert "A: --check on fresh checkout exits 1" [ "$(run --check)" -eq 1 ]
assert "A: --check changed nothing" [ ! -L "$REPO/.claude/skills/beta" ]
assert "A: install exits 0" [ "$(run)" -eq 0 ]
for n in alpha beta protocol.md; do
  assert "A: $n linked" linked "$n"
  assert "A: $n excluded" excluded "$n"
done
assert "A: non-skill file not linked" [ ! -e "$REPO/.claude/skills/notes.txt" ]
bit="$(git -C "$REPO" ls-files -v -- .claude/skills/alpha/SKILL.md | cut -c1)"
assert "A: tracked alpha/SKILL.md skip-worktree'd" [ "$bit" = S ]
assert "A: git status clean" [ -z "$(git -C "$REPO" status --porcelain)" ]
assert "A: --check now converged" [ "$(run --check)" -eq 0 ]

# --- B: idempotent ---------------------------------------------------------
cp "$REPO/.git/info/exclude" "$REPO/../excl.$$"
assert "B: second run exits 0" [ "$(run)" -eq 0 ]
assert "B: second run made no changes" bash -c "! grep -q DID '$REPO/../log.$$'"
assert "B: exclude unchanged" diff -q "$REPO/../excl.$$" "$REPO/.git/info/exclude"

# --- C: deleting a skill upstream prunes its link and exclude entry --------
rm -rf "$PKG/claude/skills/beta"
assert "C: --check flags the stale link" [ "$(run --check)" -eq 1 ]
assert "C: install exits 0" [ "$(run)" -eq 0 ]
assert "C: beta link removed" [ ! -L "$REPO/.claude/skills/beta" ]
assert "C: beta dropped from exclude" bash -c "! grep -qxF .claude/skills/beta '$REPO/.git/info/exclude'"
assert "C: alpha untouched" linked alpha
assert "C: only one managed block" [ "$(grep -cxF '# >>> coder-packages skills >>>' "$REPO/.git/info/exclude")" -eq 1 ]

# --- D: unrelated links and the user's own exclude lines are left alone ----
setup
ln -s /tmp "$REPO/.claude/skills/someone-elses"
printf 'my-own-ignore\n# >>> autopilot skills >>>\n.claude/skills/daily-brief\n# <<< autopilot skills <<<\n' >>"$REPO/.git/info/exclude"
assert "D: install exits 0" [ "$(run)" -eq 0 ]
assert "D: foreign symlink kept" [ -L "$REPO/.claude/skills/someone-elses" ]
assert "D: user exclude line kept" grep -qxF my-own-ignore "$REPO/.git/info/exclude"
assert "D: legacy autopilot block removed" bash -c "! grep -qF 'autopilot skills' '$REPO/.git/info/exclude'"
assert "D: converged after migration" [ "$(run --check)" -eq 0 ]

# --- E: non-git checkout fails loudly --------------------------------------
REPO="$(mktemp -d)"
assert "E: non-git JOURNEY_ROOT exits 1" [ "$(run)" -eq 1 ]

if [[ "$FAILURES" -eq 0 ]]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
