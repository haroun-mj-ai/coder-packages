---
name: ship-work
description: Take the code an approved plan produced and land it on dev: commit, push, open the PRs, rebase, wait for CI, fix a red check within a strict budget, then merge in dependency order and update Linear. Stops hard on human review comments, semantic conflicts, security findings, or scope creep. Use after /implement-plan when asked to ship, land, or open PRs for finished work. Never touches main or production.
---

# ship-work

Third and last skill in the chain: `/plan-issue` designs, `/implement-plan` builds,
this lands it on `dev`. It stops at `dev`. Anything involving `main` is a
production deploy via Railway and stays a human decision.

## Usage

```
/ship-work                                # infer from current branch + newest plan
/ship-work docs/plans/2026-07-31-eng-123-foo.md
/ship-work --dry-run                      # read-only: report exactly what it would do
/ship-work --no-merge                     # stop at green and mergeable
```

Use `--dry-run` the first few times. It performs every read and prints the action
plan (PRs it would open, bases, merge order) without mutating anything.

## Hard stops

These end the run immediately. Report what landed, what did not, and the one next
action, then stop. **Do not proceed to the next repo**, because a partial
cross-repo landing is the worst state to leave staging in.

1. **A human left a review comment or requested changes** on any PR. Never resolve
   another person's feedback autonomously, even if the fix looks obvious.
2. **A semantic rebase conflict.** Trivial classes are resolved deterministically
   (see step 6); anything in real code stops.
3. **Any secret-scanning or security finding**, including push protection firing
   or a secret-shaped string in the diff. Stop loudly, do not retry, do not
   rewrite history to hide it.
4. **The diff touches files the plan never named.** Catches an implementer that
   widened scope and a stray unrelated edit in one check.
5. Two failed fix attempts on the same red check.
6. Anything that would touch `main`, force-push a shared branch, or merge a PR
   whose base is not `dev` (or `main` for `assistants`/`observability`, which have
   no `dev`).

Being stopped is a success condition for this skill. A clear halt beats a confident
merge of something half-understood.

## Repo map

MCP calls need `owner`/`repo`; the local paths are gitignored siblings.
`<root-repo>` below is this repo's own absolute path — resolve with
`git -C . rev-parse --show-toplevel` rather than hardcoding, since it differs
per machine.

- root `<root-repo>` → `JourneyAI-Team/root-for-local`, base `dev`
- `backend/` → `JourneyAI-Team/journeyai-backend`, base `dev`
- `frontend/` → `JourneyAI-Team/frontend`, base `dev`
- `assistants/` → `JourneyAI-Team/assistants`, base `main`
- `observability/` → `JourneyAI-Team/observability`, base `main`

Every git command takes `git -C <abs-path>`. **PRs go through the GitHub MCP
tools, never the `gh` CLI.** Pushes go over git SSH.

## What CI actually checks, per repo

Knowing this is the difference between waiting for a signal and waiting forever.

- **`backend/`**: `Backend CI` on `pull_request` to `dev`/`main`. Job `lint` runs
  `ruff check` and `ruff format --check`, both `continue-on-error: true`, so **ruff
  never gates a merge**. Job `test` runs `pytest tests/ --cov` and **does** gate.
- **`frontend/`**: `Frontend CI` on `pull_request`. Jobs `lint`
  (`npm run lint` plus `npx tsc --noEmit`), `test` (`npm run test:coverage`),
  `build` (`npm run build`), `dependency-review`. **All blocking.** Note the
  asymmetry: a single eslint error or type error fails the frontend PR while the
  backend shrugs at hundreds of ruff errors.
- **root**: **no PR-triggered workflows at all.** `e2e.yml` is
  `workflow_dispatch` plus a nightly cron; `release-notify.yml` is manual. A root
  PR will show zero checks. Do not wait for CI on it and do not report "green":
  say plainly that root has no PR gate and that the local quality gates were the
  only signal.
- **`assistants/`, `observability/`**: no workflows at all. Same treatment.

No repo has a CODEOWNERS file or a PR template, so nobody is auto-requested as a
reviewer and there is no template to fill. Do not add reviewers unless asked;
requesting a review pings a teammate.

## Instructions

### 1. Establish what is being shipped

Read the plan named in the argument, or infer it from the current branch name and
take the newest matching file in `docs/plans/`. Confirm the inference out loud
before acting on it.

You need from the plan: the ticket id, the work units with their repos, the
dependency edges between units, and the file list per unit. If the plan has no
**Design review** section it was never dry-run reviewed, and shipping it is not
this skill's call to make: stop and say so.

Then, per repo the plan touches:

```bash
git -C <abs-path> status -sb
git -C <abs-path> log --oneline origin/dev..HEAD
```

Detect and skip work that is already done. An already-merged branch, an open PR
that exists, a commit already on `dev` (`git -C <path> branch -r --contains HEAD`)
means resume from the next unfinished step rather than redoing it.

### 2. Gate on scope, then on secrets

**Scope (hard stop 4).** For each repo, list the changed files and compare against
the union of the plan's per-unit file lists:

```bash
git -C <abs-path> diff --name-only origin/dev...HEAD
git -C <abs-path> status --porcelain
```

Files outside the plan stop the run. Report them individually: an implementer that
widened scope and an unrelated stray edit look identical here and both deserve
your eyes. Test files the plan implied but did not name by exact path are fine;
new source files it never mentioned are not.

**Secrets (hard stop 3).** Before anything leaves the machine, scan what is about
to be committed, not the whole tree:

```bash
git -C <abs-path> diff --cached -U0 | grep -nE \
  'sk-[A-Za-z0-9]{16,}|sk_live_|rk_live_|AKIA[0-9A-Z]{16}|xox[baprs]-|ghp_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
```

Any hit stops the run. This tree has leaked live Stripe, OpenAI, and JWT secrets
before, via `git add -A`. Which is why: **stage explicit paths, never `git add -A`,
not even here.**

One known false positive: the pattern above matches **this file**, since the
pattern is literally written here. A hit whose only match is the regex source in a
`.claude/` doc is not a finding. Confirm the matched line is a real value, not a
pattern definition or a test fixture, before treating it as hard stop 3. Never
loosen the pattern to make a hit go away.

### 3. Local gates before remote gates — reuse `/implement-plan`'s result when it is still valid

Do not blindly re-run what the previous phase already ran. `/implement-plan`
writes a QA artifact at `docs/plans/qa/<eng-id>-qa.md` whose header names the
exact commit the gates ran against and their pass/fail result — read it first:

```bash
cat docs/plans/qa/<eng-id>-qa.md | head -6   # Issue / Commit / Gates / Relaunch / PRs
```

**Skip re-running a repo's gates** only when all of the following hold:

- the artifact exists and its header parses (`Issue:`, `Commit:`, `Gates:` all
  present);
- the current `HEAD` of that repo's worktree/branch matches the SHA the header
  recorded for it exactly (`git -C <path> rev-parse HEAD`);
- the header's `Gates:` line records that repo's gates as passing.

State this explicitly in the report when it applies: *"gates reused from
`docs/plans/qa/<eng-id>-qa.md`, HEAD unchanged at `<sha>`."* This is safe
specifically because the artifact pins the exact commit the gates were run
against — if `HEAD` still equals that commit, nothing has changed since they
ran, so re-running would reproduce the same result at the cost of a full test
suite.

**Re-run in full whenever any of the following holds** — this is the mandatory
fallback, not an edge case to special-case away:

- any touched repo's `HEAD` differs from the SHA the header recorded (a rebase
  in step 6, or a fixup commit, moves `HEAD` and invalidates the pin);
- the artifact is missing, or its header is missing or unparseable;
- the header records any gate as failing.

A stale green is worse than a slow gate: a rebase or a fix commit changes the
SHA the artifact was written against, so a green result recorded there says
nothing about the code actually about to be pushed. When in doubt, re-run.

```bash
cd frontend && npm run lint && npx tsc --noEmit && npm run test:coverage && npm run build
cd backend  && poetry run pytest
```

Mirror what CI runs, not what is convenient: frontend CI runs `test:coverage`, not
`test:run`, and it runs `tsc --noEmit` separately from `build`. Note also that this
step's own gate list (`lint`, `tsc --noEmit`, `test:coverage`, `build`) is a
superset of `/implement-plan`'s (`build`, `test:run`) for frontend — even a
freshly reused SHA never skips `lint`, `tsc --noEmit`, or `test:coverage`
unless the artifact's `Gates:` line explicitly names those as having passed
too. If the artifact only ever records the narrower implement-plan gate set,
treat this repo's gates as unrecorded and run the full CI-mirroring set here.

Known noise, which is not a reason to stop: backend endpoint tests failing in
isolation on uninitialized Beanie, and the `test_specs_phase3`/`phase4` failures
from `assistants/` template drift, which CI skips. Baseline against untouched
`dev` before attributing any failure to this change.

### 4. Commit and push

One coherent commit per work unit, or one per repo when the units are small.

- subject `ENG-<id>: <what changed>`
- stage **explicit paths**
- trailers: **only** the user's two `Co-Authored-By` lines. Never an assistant or
  Claude co-author trailer. The tracked `commit-msg` hook adds both idempotently on
  local commits. It does **not** run for commits made through the GitHub MCP write
  tools or a web-UI squash-merge, so type them into the message yourself on those
  paths. Confirm either way with `git -C <path> log -1 --format=%B`.
- `git -C <path> push -u origin <branch>`

After every push, and after every later force-push, **verify by content**:

```bash
git -C <path> fetch origin <branch> --quiet
git -C <path> diff --stat HEAD origin/<branch>    # must be empty
```

An amend plus force-push around merge time has silently dropped a fix here before.
The push command's own output is not evidence.

### 5. Open the PRs

`mcp__github__create_pull_request`, one per repo, base per the repo map. Open all
of them before merging any, so a reviewer can see the change as one thing.

- **title** `ENG-<id>: <what changed>`
- **body**, in this order: what changed and why (two or three lines), the work
  units it covers, verbatim test evidence, the QA plan, a link or path to the plan
  doc, and any screenshots from browser QA.
- **`Part of ENG-<id>`** in the body. Never `Fixes`, `Closes`, or `Resolves`:
  closing keywords auto-close the Linear-linked issue, and only a reviewer marks
  work `Done`.
- cross-link the sibling PRs by URL when a ticket spans repos, and state the
  required landing order in each body.

**Once every PR is open, fill the QA artifact's `PRs:` line.** Edit
`docs/plans/qa/<eng-id>-qa.md`'s header — replace `PRs: (filled in by
ship-work)` with the opened URLs, one line, e.g. `PRs: backend
<url>, frontend <url>, root <url>` — and commit that single-line change on its
own, `ENG-<id>: record PR URLs in QA artifact`, staged with the explicit path.
This is the **only** edit `/ship-work` makes to the artifact: everything else
in the file (the four QA sections, the `Commit:`/`Gates:`/`Relaunch:` lines) is
`/implement-plan`'s to write, and this skill does not second-guess or
re-derive them. `/test-issue` later reads this same line instead of
re-discovering PR numbers through `gh pr list`.

### 6. Rebase, and keep rebasing

The convention here is rebase, not merge commits into the feature branch, so do it
locally rather than with `update_pull_request_branch` (which creates a merge
commit):

```bash
git -C <path> fetch origin dev --quiet
git -C <path> rebase origin/dev
git -C <path> push --force-with-lease
```

Then verify by content as in step 4.

**Resolve deterministically or stop.** Only these classes may be resolved
automatically, and each gets a line in the final report:

- lockfiles (`package-lock.json`, `poetry.lock`): take theirs and regenerate with
  the real tool, never hand-merge the file
- import ordering, formatter-only churn
- append-only list files where both sides added a distinct line

Everything else is a semantic conflict and a hard stop. When both sides changed
the same logic, an agent guessing which intent wins is how a fix disappears
without anyone noticing.

**Re-rebase after each sibling merge.** Once the backend PR lands, the frontend PR
is green against a `dev` that predates the new API. Rebase it onto the new `dev`
and let CI run again before merging it.

### 7. Wait for CI, then classify what comes back

Read checks with `mcp__github__pull_request_read`, `method: "get_check_runs"` for
the individual jobs and `method: "get_status"` for the combined state.

Poll at an interval matched to the job, not tightly: backend `test` takes minutes.
Between polls, wait with `Monitor` rather than a foreground sleep. For repos with
no PR workflows, skip this step entirely and say so.

Classify before reacting. Fixing the wrong category is how the loop burns budget:

- **Non-blocking.** Backend `lint` red is expected: both ruff steps are
  `continue-on-error`, and `dev` already carries substantial ruff debt. Do not fix
  it, do not mass-reformat, and do not report it as a failure.
- **Pre-existing on `dev`.** Before blaming the diff, check the same job on `dev`'s
  most recent run. If `dev` is red too, this is not yours: report it, stop, and do
  not fix someone else's break inside this ticket.
- **Infrastructure or known flake.** One retry, then stop. Known instance:
  `deploy-production.yml` installs the Railway CLI by piping `install.sh` to bash,
  which is fragile in Actions. It is also a production workflow and outside this
  skill's scope, so it never gates a `dev` merge.
- **A real failure inside the diff.** Hand the job log and the failing test to an
  `implementer` (`subagent_type: "implementer"`, pinned sonnet and medium effort)
  with the plan's spec for the affected unit. **Two attempts total, then stop.** An
  agent grinding on a failure it does not understand is the exact token-burn
  pattern this whole chain exists to avoid.

Check for human activity on every poll: `method: "get_reviews"` and
`method: "get_review_comments"`. Any review comment or requested change is hard
stop 1, immediately, even mid-fix.

### 8. Merge, in dependency order

Only when a PR is green (or has no gate), has no unresolved human comment, and is
mergeable. Skip this step under `--no-merge`.

Order comes from the plan's dependency edges, not from convenience: the repo whose
API or schema the other consumes lands first, which in practice means backend
before frontend. Merge one, verify, rebase the next, wait for its CI, then merge
it.

`mcp__github__merge_pull_request` with `merge_method: "merge"`, matching the
existing history on `dev`. Never `main` as a base.

**Verify each merge by content, not by the API's word:**

```bash
git -C <path> fetch origin dev --quiet
git -C <path> show origin/dev:<a-file-the-change-touched> | grep <a-signature-line>
```

Linear status and a 200 from the merge call are both consistent with the fix
having been dropped by a force-push that raced the merge.

### 9. Close out

- Linear → `Staging` for each merged repo, per `AGENTS.md` §2. Comment the PR URLs
  on the issue. **Never** set `Done`; a reviewer does that after verification.
- Archive the plan: `mkdir -p docs/plans/completed`, `git mv` it there, set
  `Status: Completed`. Mandatory per `AGENTS.md` §5. The plan lives in root, so
  fold this into the root PR when the ticket already has one. When it does not,
  open a small root PR carrying just the archive rather than pushing straight to
  `dev`.
- Final report: what merged and where, PR URLs, what CI actually verified per repo
  (and where there was no gate at all), every conflict resolved automatically,
  every fix attempt spent, and what remains for a human. If anything stopped the
  run, lead with that.
- After a successful merge, remove the worktree and local branch for the issue in
  every repo that merged — the same never-force rules as everywhere else in this
  skill: `git -C <repo> worktree remove <path>` (never `--force`) then
  `git -C <repo> branch -d <branch>` (never `-D`), and only once the branch is
  actually merged into its base and the worktree is clean. `autopilot/bin/ap-sweep.sh`
  (`ap sweep`) does exactly this check on a schedule for anything left behind — use
  it (`ap sweep --yes`) instead of hand-rolling the same check for the periodic
  cleanup case, or when cleaning up several issues' worktrees at once.

## Headless mode (--headless)

Shared vocabulary, `status.json` shape, inbox contract, and the ask→fallback
rule live in `.claude/skills/autopilot-protocol.md` — read it first; this
section only states what maps to what for this skill.

`--headless` **implies `--no-merge`, non-negotiable.** Step 8 (merge) is
unreachable under `--headless` regardless of what the invocation otherwise
says — there is no headless path into that step, even if a caller passes
`--headless` without also passing `--no-merge`. Merging is always the human's
interactive `/ship-work` run. (Defense in depth: the autopilot permission
profile also denies the merge tool; this is a second, independent guarantee
inside the skill's own text.)

Pushing feature branches and opening PRs against `dev` **is** pre-approved
under `--headless` — that standing authorization is precisely why this skill
is part of the autopilot chain. Nothing else about the existing rules
loosens: never `main`, never a direct push to `dev` itself, and the only
force-push is the lease-guarded `git push --force-with-lease` in step 6's
rebase, exactly as interactive.

Each of the six **Hard stops** above, hit under `--headless`, ends the run as
`NEEDS_HUMAN` per the protocol's ask→fallback rule: post the stop reason
(which numbered hard stop, and the evidence — the review comment, the
conflicting diff, the finding string, the out-of-plan file list, the second
failed check, or the main/force-push/wrong-base attempt) as a comment on the
inbox issue, prefixed with the line `Phase: ship` per the protocol's
ask→fallback rule, swap its label `shipping` → `needs-input` (the wrapper
already swapped `building` → `shipping` before invoking this phase), and
write `status.json` with `status: NEEDS_HUMAN`, `phase: "ship"`, and
`question` set to that same text.
Never continue past a hard stop headlessly — the interactive rule ("stop,
report, do not proceed to the next repo") holds unchanged; headless mode only
changes where the stop is reported.

**Success end state** (all gates clear, PRs open and green or gateless, no
merge): PR URLs are posted as a comment on the inbox issue and the inbox
label is swapped `shipping` → `ready-to-test`. On Linear — the one write beyond the
claim, and it is a label, not a comment — add label `agent:ready-to-test`;
Linear status stays `In Progress`. Headless ship-work never posts a Linear
comment, success or failure; the PR link(s) live on the inbox issue only.
Never `Staging` headlessly (`Staging` means merged, and headless ship-work
never merges) and never `Done` (a reviewer sets that, same as interactive).
Write `status.json` with `status: "DONE"`, `phase: "ship"`, and `pr_urls`
filled with every opened PR URL.

Plan archiving (`docs/plans/` → `docs/plans/completed/`) does **not** happen
under `--headless` — it stays exactly where step 9 leaves it today, performed
only by the human's later interactive `/ship-work` run that actually merges.

**Never end the turn with work still in the background — this is how headless
ship-work dies most often.** The `-p` harness ends the process when your turn
ends: there is no later turn in which a background task's result comes back to
you. Waiting on CI is exactly where this bites. A real run (ENG-1199,
2026-08-12) finished its turn saying *"that worked and is running in the
background, I'll wait for it to finish"* — the process exited, `status.json` was
never written, and the wrapper correctly reconciled a successful push as a
crash.

So, in headless mode:

- Poll CI with **blocking foreground** commands (`gh pr checks <n> --watch`, or
  a bounded loop of `gh pr checks <n>` calls you actually wait on inside the
  turn). Never park the wait in a background task and end your message.
- Treat writing `status.json` as the last thing that must complete before
  anything else is allowed to still be running. If you genuinely cannot finish
  the wait inside the turn, write `status.json` FIRST with what you know —
  `NEEDS_HUMAN` naming the PR and the pending check, or `FAILED` with
  `detail: "CI wait exceeded the turn"` — so the run is reconcilable and the
  next cycle (or the owner) can pick it up from a known state.
- The same rule covers `roborev --wait`, long test suites, and anything else
  you would be tempted to background: if it must run, run it in the foreground;
  if it cannot, record state before yielding.
