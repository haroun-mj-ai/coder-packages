---
name: piv-commit
description: Creates a new git commit for all uncommitted changes with an atomic, conventionally-tagged message. Use when work is complete and ready to be committed.
---

# Commit: Create a New Commit

Create a new commit for all of our uncommitted changes.

## Process

0. **Read this project's conventions.** If `.claude/references/conventions.md` exists, read its `## commit`
   section and follow it — those rules win over the defaults below. That file is where a project's specifics
   live; this skill stays general.
1. Run `git status && git diff HEAD && git status --porcelain` to see what files are uncommitted.
2. Add the untracked and changed files.
3. Write an atomic commit message with an appropriate, descriptive summary.
4. Add a tag such as `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, etc. that reflects our work.

## Output

A single commit containing all uncommitted changes, with a conventional-commit-style message
(`<tag>: <atomic description>`) that accurately reflects the work done.

After the commit succeeds, print two clearly labelled summaries:

### What Changed
One short paragraph (3–6 sentences) describing the feature/fix/refactor that was committed — what problem it solves and what files were the key touch points. Write for a developer skimming the git log.

### AI Layer Changes
Only include this section if any files under `.claude/` were modified or added (CLAUDE.md, `.claude/references/`, `.claude/skills/`, `.claude/agents/`, etc.).

List each changed AI-layer file with a one-line note on what evolved and why. If nothing in `.claude/` changed, omit this section entirely.

## Headless mode (--headless)

Read `.claude/skills/headless-protocol.md` first — the `status.json` shape, the local queue contract, the ask→fallback rule, the Linear footprint are defined once there. This section states only what this skill's own ask points map to.

**No ask points exist** in this skill's 33-line procedure — don't go looking for a mapping table here, there isn't one.

**This skill is never dispatched as its own act.** It runs inside the build-phase act — `fix` for a bug (invoked by `piv-implement-issue`), `build` for a feature (invoked by `piv-implement`, once that fork ships) — and inherits that session's ENG id and worktree either way. It therefore writes **no** `status.json` of its own — the enclosing act writes one for the whole phase.

**Capture the commit SHA.** Immediately after the commit succeeds, run `git rev-parse HEAD` and hand the short SHA back to the caller for `status.json`'s `detail` and the ticket's `history`. It is what `babysit-pr`'s replies cite ("Confirmed and fixed in `a1b2c3d`", `babysit-pr/SKILL.md:204`).

**On any git failure** (nothing staged, a pre-commit hook rejection, a lock file): do not retry, do not amend, do not `git reset`. Report the exact failing command and stderr to the caller, which writes `FAILED` with that text in `detail`. `Bash(git reset --hard *)` is on the profile's **deny** list — never attempt a recovery through it.

**The commit must include** the implementation, its tests, the approved artifact (the RCA or the plan) if this is the first commit on the branch, and the phase's report. Nothing else: an out-of-plan file in the commit becomes an out-of-scope finding in the very next phase's review.

**`.claude/` AI-layer summary** (above): still printed when applicable, as prose to the caller; nothing extra headlessly.

Do not add a queue write here. Two skills writing the same ticket inside one act is how a `history` trail becomes unreadable; the enclosing phase owns the write.
