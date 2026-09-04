---
name: piv-create-pr
description: Push the current feature branch and open a pull request, ready for review. Use after a ticket's implementation is committed on its own branch — it detects the base branch, pushes, opens the PR with a clear body (summary · what changed · validation status), and returns the URL to hand to a reviewer.
argument-hint: "[--base <branch>] (default: auto-detected)"
---

# Create PR: Open the Pull Request, Hand Off for Review

This is the **ship** step of the PIV loop: the implementation is committed on a feature branch; now open the PR
so it can be reviewed (by the `piv-review-pr` agentic gate, then a human).

## Phase 0 — Detect the base branch

Don't hardcode `main`. Resolve it:
1. If `$ARGUMENTS` contains `--base <branch>`, use that.
2. Else: `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`
3. Fallback: `git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}'`
4. Last resort: `main`. Store as `{base}`.

**This project, specifically:** root/`backend/`/`frontend/` base to `dev`; `assistants/`/`observability/` base to
`main` (no `dev` branch there) — confirmed by step 2 above per repo, never assumed from one repo's answer.

## Multi-repo tickets — run this skill once per touched repo

A ticket that spans repos (root + `backend/` + `frontend/`, say) gets **one PR per repo**, not one combined PR —
run Phases 0-3 once with `cwd` set to each repo/worktree that has commits ahead of its base. After every PR in the
set is open:

- **Cross-link them.** Add each sibling PR's URL to every other PR's body under "Linked," and state the required
  merge order (if any) — the human merging reads this to decide sequencing, since nothing here merges anything.
- Use **`Part of ENG-<id>`** in the body, never `Fixes`/`Closes`/`Resolves` — those auto-close the tracker issue,
  and only a human marks a multi-repo ticket done once every sibling PR has landed.

## Phase 1 — Validate git state

```bash
git branch --show-current
git status --short
git log origin/{base}..HEAD --oneline
```

| State | Action |
|-------|--------|
| On `{base}` | STOP: "Create a feature branch first (the ticket should be on its own branch)." |
| Uncommitted changes | STOP: "Commit (or stash) before opening the PR." |
| No commits ahead of `{base}` | STOP: "Nothing to PR." |
| Existing PR for this branch (`gh pr list --head $(git branch --show-current) --json url`) | STOP and print the URL. |
| Clean, commits ahead, no PR | PROCEED |

## Phase 2 — Gather context for the body

- **Project conventions:** if `.claude/references/conventions.md` exists, read its `## pr` section — its rules
  win over the default template below (sections, tone, what must be stated). That file is where a project's
  specifics live; this skill stays general.
- Commits: `git log origin/{base}..HEAD --pretty=format:"- %s"`
- Files: `git diff --stat origin/{base}..HEAD`
- **Implementation report** (if `piv-implement` wrote one — `.claude/reports/<…>-report.md`): pull the summary,
  validation results, and **documented deviations** (these belong in the PR body — they tell the reviewer what
  was intentional).
- Linked ticket / issue: look for `ENG-…` (Linear), `ACC-…`, `#123`, `Fixes #…` in the commits/branch name.
- PR template: if `.github/PULL_REQUEST_TEMPLATE.md` exists, fill it; else use the default below.

## Phase 3 — Push and open the PR

```bash
git push -u origin HEAD
```

```bash
gh pr create --base "{base}" --title "{type}: {concise description}" --body "$(cat <<'EOF'
## Summary
{1-2 sentences: what this ticket delivers}

## What changed
{commit summaries}

## Validation
- Tests / type-check / lint: {pass/fail from the implementation report or a fresh run}
- Manual check: {what was exercised, or "pending review"}

## Notes for the reviewer
{documented deviations from the plan — intentional decisions — or "none"}

## Linked
{ticket / issue refs, or "none"}

_Ready for review._
EOF
)"
```

(`{type}` = feat/fix/refactor/… from the work. Use `--draft` if the work isn't ready for a real review.)

## Output

```bash
gh pr view --json number,url,title,baseRefName,headRefName
```

Report the PR number + URL, the base ← head branches, and **"Ready for review → run `piv-review-pr <number>`, then a
human approves."** This is the handoff point: the agent's loop ends at an open PR; review and merge are the gates.

## Notes

- Tool-agnostic in spirit: this skill uses GitHub (`gh`); the same motion is "open a merge request" on GitLab,
  or "mark ready for review" wherever your team works. Solo with no remote? Skip the PR — commit on `{base}` and
  review your own diff before moving on.
- Sets up parallel work: one branch per ticket → one PR per ticket is exactly what makes worktree parallelism
  (running independent tickets at once) clean.

## Headless mode (--headless)

Read `.claude/skills/headless-protocol.md` first — the `status.json` shape, the local queue contract, the ask→fallback rule, the Linear footprint are defined once there. This section states only what this skill's own ask points map to.

**Never its own act.** This skill runs inside the `fix` act (bug) or the `build` act (feature, once that fork ships) — same inheritance and no-`status.json` rule as `piv-commit`.

**Precondition mapping** (Phase 1 table above) — all five are deterministic fail-fast checks, not human-judgment asks, so **none** becomes `NEEDS_HUMAN`:

| precondition | headless resolution |
|---|---|
| On `{base}` | `FAILED`, `detail: "on base branch; the fix act's worktree mandate was not honoured"` |
| Uncommitted changes | `FAILED`, `detail` = the `git status --short` output |
| No commits ahead of `{base}` | `FAILED`, `detail: "nothing to PR"` |
| Existing PR already open for this branch | **`DONE`-idempotent**: print and return the URL as a success, not a failure — this is the normal state on a retried `fix` act |
| Clean, ahead, no PR | proceed |

**Push with the explicit branch name.** `git push -u origin HEAD` as written in Phase 3 above would actually pass under the current profile via the pre-existing `Bash(git -C *)` allowance (e.g. `git -C <worktree> push -u origin HEAD` matches). It is still the wrong thing to do, on its own terms: pushing `HEAD` rather than the explicit branch name loses the branch-naming discipline every other worktree in this repo follows, makes retries harder to reason about (which branch did a prior attempt actually push?), and produces a remote branch name a human reading `git branch -a` can't correlate to the ticket at a glance. Push the **explicit branch name the act's worktree is already on**: `haroun/eng-<id>-fix-<slug>` for a bug, `haroun/eng-<id>-<slug>` for a feature (once that fork ships). So: `git -C <worktree> push -u origin haroun/eng-<id>-fix-<slug>` for this fork — enforced by convention in this skill's prose, not by the permission profile.

**Opening the PR.** `gh pr create` genuinely **is not** on the allow list today, and unlike `git` there is no `Bash(gh -C *)`-style escape hatch already granted for `gh`. Either use the already-allowed `mcp__github__create_pull_request`, or rely on the permission profile eventually adding `Bash(gh pr create *)`. State the preference: prefer the **MCP tool**, per the protocol's own "prefer the allowed GitHub MCP tools over `gh` when one fits" rule, which also sidesteps the heredoc-in-a-compound-command shape in Phase 3 above that the no-pipes/no-compound rule makes fragile.

**Body content**: unchanged from Phase 2/3 above, plus a **kind-branched implementation-report lookup** — this is what the "Implementation report (if `piv-implement-issue` wrote one — `.claude/reports/<…>-report.md`)" lookup becomes once a feature fork exists alongside this one:

| ticket kind | report path folded into the PR body | approved artifact linked under `## Linked` |
|---|---|---|
| bug | `docs/issues/reports/<ENG-ID>-fix-report.md` | the RCA, `docs/issues/issue-<ENG-ID>.md` |
| feature | `docs/plans/reports/<ENG-ID>-<slug>-report.md` | the plan, `docs/plans/<ENG-ID>-<slug>.md` |

Both are resolvable the same deterministic way — anchored on the ENG id at a fixed relative path — and **both are committed by `/piv-commit` inside the same act**, so the lookup never races an unwritten file. `<slug>` is the plan file's own slug, so the report name is derivable from the plan path with a suffix, not from a second convention. Keep `Part of ENG-<id>`, never `Fixes`/`Closes`/`Resolves`, for both.

**Multi-repo** (above): unchanged headlessly — one PR per touched repo, cross-linked, merge order stated. Every URL goes into the act's `pr_urls`.

**Output**: return PR number + URL + base←head to the caller. Do **not** print the interactive "run `piv-review-pr`" handoff as an instruction — the orchestrator dispatches that as its own act from the `piv-review-pending` state.

`docs/plans/` **is tracked** in the work repo, so it exists in any fresh worktree — unlike `docs/issues/`, which needs creation for the bug path. `docs/plans/reports/` is new and does not exist in HEAD, for whichever fork writes to it first: create it before writing, same as `docs/issues/`.

Never `main`, never a direct push to `dev` itself, never a merge call — nothing here loosens those limits.
