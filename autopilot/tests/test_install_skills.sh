#!/usr/bin/env bash
# Self-contained test for scripts/install-autopilot.sh's step 6 (autopilot
# skills wiring into the JourneyAI checkout). Runs the real installer
# against a throwaway $HOME and a throwaway `git init` repo standing in for
# the JourneyAI checkout ($AP_WORK_REPO) -- no network, never touches the
# real ~/.bashrc, ~/.autopilot, or the real JourneyAI checkout.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$SCRIPT_DIR/scripts/install-autopilot.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

assert() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

SKILL_NAMES=(plan-issue implement-plan ship-work autopilot-poll daily-brief autopilot-protocol.md)

skip_worktree_bit() {
  # skip_worktree_bit <repo> <path> -> the ls-files -v status letter
  git -C "$1" ls-files -v -- "$2" | cut -c1
}

# =============================================================================
# Case A: fresh fake JourneyAI checkout with one dummy tracked file under
# .claude/skills/plan-issue/SKILL.md (standing in for the team-tracked
# SKILL.md files the real checkout has). Running the installer once must:
#   - symlink all six .claude/skills/<name> entries into this repo's
#     claude/skills/<name> (the real source -- ROOT_DIR is fixed, not faked)
#   - skip-worktree the one path git already tracks (plan-issue/SKILL.md)
#   - leave the other five untouched by the skip-worktree step (nothing
#     tracked there in this fake repo, same as autopilot-poll/daily-brief/
#     autopilot-protocol.md in the real one)
#   - append the marked fence block to .git/info/exclude
# =============================================================================
FAKE_HOME="$(mktemp -d)"
FAKE_REPO="$(mktemp -d)"

git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.email "test@example.com"
git -C "$FAKE_REPO" config user.name "Test"
mkdir -p "$FAKE_REPO/.claude/skills/plan-issue"
echo "dummy tracked SKILL.md" >"$FAKE_REPO/.claude/skills/plan-issue/SKILL.md"
git -C "$FAKE_REPO" add .claude/skills/plan-issue/SKILL.md
git -C "$FAKE_REPO" commit -q -m "dummy tracked skill file"

run_installer() {
  # run_installer [--check] -> exit code
  HOME="$FAKE_HOME" AP_WORK_REPO="$FAKE_REPO" bash "$INSTALLER" "$@" \
    >"$FAKE_HOME/install.log" 2>&1
  echo $?
}

rc="$(run_installer)"
assert "caseA: installer exits 0 on first run" [ "$rc" -eq 0 ]

for name in "${SKILL_NAMES[@]}"; do
  dest="$FAKE_REPO/.claude/skills/$name"
  src="$SCRIPT_DIR/claude/skills/$name"
  assert "caseA: $name symlinked" [ -L "$dest" ]
  assert "caseA: $name symlink target is $src" \
    bash -c "[ \"\$(readlink '$dest')\" = '$src' ]"
done

bit="$(skip_worktree_bit "$FAKE_REPO" .claude/skills/plan-issue/SKILL.md)"
assert "caseA: tracked plan-issue/SKILL.md is skip-worktree ('s' or 'S')" \
  bash -c "[ '$bit' = s ] || [ '$bit' = S ]"

EXCLUDE_FILE="$FAKE_REPO/.git/info/exclude"
assert "caseA: exclude file has the marked fence" \
  bash -c "grep -qF '# >>> autopilot skills >>>' '$EXCLUDE_FILE'"
for name in "${SKILL_NAMES[@]}"; do
  assert "caseA: exclude file lists .claude/skills/$name" \
    bash -c "grep -qxF '.claude/skills/$name' '$EXCLUDE_FILE'"
done

# --check must now report full convergence (exit 0) with no further changes
# implied -- prove it by diffing the exclude file's content across a second
# real run (idempotency).
rc_check="$(run_installer --check)"
assert "caseA: --check exits 0 once converged" [ "$rc_check" -eq 0 ]
assert "caseA: --check output has no MISSING lines" \
  bash -c "! grep -q MISSING '$FAKE_HOME/install.log'"

exclude_before_file="$FAKE_HOME/exclude-before.snapshot"
cp "$EXCLUDE_FILE" "$exclude_before_file"
symlink_target_before="$(readlink "$FAKE_REPO/.claude/skills/plan-issue")"
bit_before="$(skip_worktree_bit "$FAKE_REPO" .claude/skills/plan-issue/SKILL.md)"

rc2="$(run_installer)"
assert "caseA: second (idempotent) real run exits 0" [ "$rc2" -eq 0 ]
assert "caseA: second run reports no DID lines for the skills step" \
  bash -c "! grep -q 'DID.*skip-worktree\|DID.*linked\|DID.*exclude' '$FAKE_HOME/install.log'"
assert "caseA: exclude file unchanged by the second run" \
  diff -q "$exclude_before_file" "$EXCLUDE_FILE"
assert "caseA: plan-issue symlink target unchanged by the second run" \
  bash -c "[ \"\$(readlink '$FAKE_REPO/.claude/skills/plan-issue')\" = '$symlink_target_before' ]"
bit_after="$(skip_worktree_bit "$FAKE_REPO" .claude/skills/plan-issue/SKILL.md)"
assert "caseA: skip-worktree bit unchanged by the second run" \
  bash -c "[ '$bit_after' = '$bit_before' ]"

# =============================================================================
# Case B: --check against a completely unconverged fake checkout (nothing
# symlinked yet) must exit 1 and change nothing on disk.
# =============================================================================
FAKE_HOME_B="$(mktemp -d)"
FAKE_REPO_B="$(mktemp -d)"
git -C "$FAKE_REPO_B" init -q
git -C "$FAKE_REPO_B" config user.email "test@example.com"
git -C "$FAKE_REPO_B" config user.name "Test"
mkdir -p "$FAKE_REPO_B/.claude/skills/plan-issue"
echo "dummy tracked SKILL.md" >"$FAKE_REPO_B/.claude/skills/plan-issue/SKILL.md"
git -C "$FAKE_REPO_B" add .claude/skills/plan-issue/SKILL.md
git -C "$FAKE_REPO_B" commit -q -m "dummy tracked skill file"

rc_b="$(HOME="$FAKE_HOME_B" AP_WORK_REPO="$FAKE_REPO_B" bash "$INSTALLER" --check \
  >"$FAKE_HOME_B/install.log" 2>&1; echo $?)"
assert "caseB: --check on unconverged checkout exits 1" [ "$rc_b" -eq 1 ]
assert "caseB: --check did not create the plan-issue symlink" \
  [ ! -L "$FAKE_REPO_B/.claude/skills/plan-issue" ]
assert "caseB: --check did not add the marked fence to .git/info/exclude" \
  bash -c "! grep -qF '# >>> autopilot skills >>>' '$FAKE_REPO_B/.git/info/exclude' 2>/dev/null"

# =============================================================================
# Case C: AP_WORK_REPO pointing at a plain (non-git) directory must not
# crash the installer -- it reports MISSING and skips the skills-wiring
# section entirely.
# =============================================================================
FAKE_HOME_C="$(mktemp -d)"
FAKE_NONGIT_C="$(mktemp -d)"

rc_c="$(HOME="$FAKE_HOME_C" AP_WORK_REPO="$FAKE_NONGIT_C" bash "$INSTALLER" \
  >"$FAKE_HOME_C/install.log" 2>&1; echo $?)"
assert "caseC: installer exits 0 even when AP_WORK_REPO isn't a git checkout" [ "$rc_c" -eq 0 ]
assert "caseC: reports the checkout as not a git repo" \
  bash -c "grep -q 'is not a git checkout' '$FAKE_HOME_C/install.log'"

# =============================================================================

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
