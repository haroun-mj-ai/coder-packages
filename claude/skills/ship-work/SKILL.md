---
name: ship-work
description: Take the branch and open PR(s) /implement-issue's --phase implement already produced, get them pushed, rebased onto the latest dev, and locally gate-clean: confirm what's already open (or, for a plan predating this convention, still commit/push/open it), rebase, run the CI-mirroring local gates, then stop and report. Never waits on remote CI and never merges — both are a separate, later human action. Stops hard on human review comments, semantic conflicts, security findings, or scope creep. Use after /implement-issue's --phase implement when asked to ship or land finished work up to the PR. Never touches main or production, and never merges to dev either.
---

# ship-work

Third skill in the chain: `/implement-issue` designs (`--phase plan`), builds,
and — as the last thing its `--phase implement` does — pushes and opens the
PR(s); this skill confirms that landing is solid (scope, secrets, local
gates, rebased onto the latest `dev`) and then **stops**. It does not poll
remote CI and it does not merge. Both of those are a human's call, made
whenever they're ready to look at the PR themselves — this skill's job ends
at "pushed, rebased, locally green, reported."

**The common starting point is already-open PRs, not uncommitted code.**
Step 1's "detect and skip work that is already done" is not an edge case
here — it's the normal path, since `/implement-issue`'s Phase B step 13
already committed, rebased, pushed, and opened the PR(s) before handing off.
Steps 4-5 (commit and push, open the PRs) stay in this skill only as a
fallback: a plan predating this convention, or a manual/legacy invocation
where implement never got that far.

## Usage

```
/ship-work                                # infer from current branch + newest plan
/ship-work docs/plans/2026-07-31-eng-123-foo.md
/ship-work --dry-run                      # read-only: report exactly what it would do
```

Use `--dry-run` the first few times. It performs every read and prints the action
plan (what it would push, rebase, and open) without mutating anything.

There is no merge mode and no CI-wait mode — this skill never does either, so
there is nothing to opt out of.

## Hard stops

These end the run immediately. Report what's done, what isn't, and the one next
action, then stop. **Do not proceed to the next repo**, because a partial
cross-repo push is still confusing to leave half-reported.

1. **A human left a review comment or requested changes** on any PR. Never resolve
   another person's feedback autonomously, even if the fix looks obvious.
2. **A semantic rebase conflict.** Trivial classes are resolved deterministically
   (see step 6); anything in real code stops.
3. **Any secret-scanning or security finding**, including push protection firing
   or a secret-shaped string in the diff. Stop loudly, do not retry, do not
   rewrite history to hide it.
4. **The diff touches files the plan never named.** Catches an implementer that
   widened scope and a stray unrelated edit in one check.
5. Anything that would touch `main`, force-push a shared branch other than this
   ticket's own feature branch, or attempt to merge anything at all — merging is
   never this skill's action, on any base, under any flag.

Being stopped is a success condition for this skill. A clear halt beats a confident
push of something half-understood.

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

This is reference material for whoever reviews and merges the PR later — this
skill itself never polls these checks, but reporting them accurately in the
final summary saves the human a lookup.

- **`backend/`**: `Backend CI` on `pull_request` to `dev`/`main`. Job `lint` runs
  `ruff check` and `ruff format --check`, both `continue-on-error: true`, so
  ruff never gates a merge. Job `test` runs `pytest tests/ --cov` and does gate.
- **`frontend/`**: `Frontend CI` on `pull_request`. Jobs `lint`
  (`npm run lint` plus `npx tsc --noEmit`), `test` (`npm run test:coverage`),
  `build` (`npm run build`), `dependency-review`. All blocking. Note the
  asymmetry: a single eslint error or type error fails the frontend PR while the
  backend shrugs at hundreds of ruff errors.
- **root**: no PR-triggered workflows at all. `e2e.yml` is `workflow_dispatch`
  plus a nightly cron; `release-notify.yml` is manual. A root PR will show zero
  checks — say so plainly in the report rather than implying "green."
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

Detect and skip work that is already done. **Check `docs/plans/qa/<eng-id>-qa.md`'s
`PRs:` header first** — the normal case is that `/implement-issue`'s Phase B step 13
already committed, rebased, pushed, and opened every PR, so that line already has
the URLs and there is nothing to redo; jump straight to step 6 (rebase) once
confirmed against `git -C <path> log --oneline origin/dev..HEAD` and
`mcp__github__pull_request_read`. Fall back to discovering it yourself — an
already-merged branch, an open PR search by branch name, a commit already on `dev`
(`git -C <path> branch -r --contains HEAD`) — only when that line is missing or
stale, meaning a plan predating this convention or a manual invocation.

### 2. Gate on scope, then on secrets

Usually a **re-confirmation**, not a first discovery — `/implement-issue`'s Phase B
step 13 already ran both of these right before its own push. Run them anyway; they
are cheap, and this is the actual last checkpoint before anything leaves the
machine. Skip only the literal re-scan when step 13's report already covers the
exact commit still at `HEAD` (nothing has changed since).

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

### 3. Local gates before pushing — reuse `/implement-issue`'s (Phase B) result when it is still valid

Do not blindly re-run what the previous phase already ran. `/implement-issue`'s
Phase B (formerly `/implement-plan`) writes a QA artifact at
`docs/plans/qa/<eng-id>-qa.md` whose header names the
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
cd backend  && poetry run pytest <paths touched, or exercising the change>
```

**Backend is scoped, not whole-repo** — same rule and same reasoning as
`/implement-issue`'s Phase B step 5, so the two skills don't disagree about what
counts as a gate. Scope it to the directories/files the plan's units actually
touched or that exercise the changed behavior. A full-repo run takes many minutes
here and has never been the thing that caught a real regression in practice; the
per-unit scoped runs plus the spec-auditor / code-review / blast-radius passes are
what carry that weight. Widen to the touched top-level package(s) if you genuinely
suspect unrelated fallout — never to a bare unscoped invocation. Frontend stays
unscoped: its CI gates on `lint`/`tsc`/`test:coverage`/`build` as whole-project
commands and there is nothing to scope them to.

Mirror what CI runs, not what is convenient: frontend CI runs `test:coverage`, not
`test:run`, and it runs `tsc --noEmit` separately from `build`. Note also that this
step's own gate list (`lint`, `tsc --noEmit`, `test:coverage`, `build`) is a
superset of `/implement-issue`'s Phase B gates (`build`, `test:run`) for frontend — even a
freshly reused SHA never skips `lint`, `tsc --noEmit`, or `test:coverage`
unless the artifact's `Gates:` line explicitly names those as having passed
too. If the artifact only ever records the narrower Phase B gate set,
treat this repo's gates as unrecorded and run the full CI-mirroring set here.

A real, in-diff local gate failure (not the known noise below) gets fixed here,
in this same run, same as any other implementation defect — this step existing
at all is what lets the rest of the skill stay CI-blind: if the local mirror is
clean, remote CI failing on the same commit is either a real miss in the mirror
(worth noting) or one of the non-blocking/pre-existing/flake categories below,
not something to chase with a fix loop after the push.

Known noise, which is not a reason to stop: backend endpoint tests failing in
isolation on uninitialized Beanie, and the `test_specs_phase3`/`phase4` failures
from `assistants/` template drift, which CI skips. Baseline against untouched
`dev` before attributing any failure to this change.

### 4. Commit and push — fallback only

**Skip this step entirely when step 1 already found a commit and an open PR**
for this branch, which is the normal case now that `/implement-issue`'s Phase
B does this itself. Run it only for a plan predating that convention, or a
manual/legacy invocation that never reached implement's step 13.

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

### 5. Open the PRs — fallback only

**Skip this step entirely when step 1 already found the PR(s) open** — again
the normal case, since `/implement-issue`'s Phase B step 13 opens them as
part of finishing implementation. Run it only in the same fallback cases as
step 4.

`mcp__github__create_pull_request`, one per repo, base per the repo map. Open all
of them before reporting, so a reviewer can see the change as one thing.

- **title** `ENG-<id>: <what changed>`
- **body**, in this order: what changed and why (two or three lines), the work
  units it covers, verbatim test evidence, the QA plan, a link or path to the plan
  doc, and any screenshots from browser QA.
- **`Part of ENG-<id>`** in the body. Never `Fixes`, `Closes`, or `Resolves`:
  closing keywords auto-close the Linear-linked issue, and only a reviewer marks
  work `Done`.
- cross-link the sibling PRs by URL when a ticket spans repos, and state the
  required landing order in each body.

**Only in this fallback path, once every PR is open, fill the QA artifact's
`PRs:` line yourself.** Edit `docs/plans/qa/<eng-id>-qa.md`'s header — replace
the placeholder with the opened URLs, one line, e.g. `PRs: backend
<url>, frontend <url>, root <url>` — and commit that single-line change on its
own, `ENG-<id>: record PR URLs in QA artifact`, staged with the explicit path.
In the normal path this line is already filled by `/implement-issue`'s Phase B
step 13, and this skill never second-guesses or re-derives it — everything in
the file (the four QA sections, the `Commit:`/`Gates:`/`Relaunch:` lines, and
now usually `PRs:` too) is Phase B's to write. `/test-issue` reads this same
line instead of re-discovering PR numbers through `gh pr list`.

### 6. Rebase, and keep rebasing

`/implement-issue`'s Phase B step 13 already rebased once, right before its own
push — this step is about staying current on THIS run: if you're invoked again
later (a fixup, a sibling repo's PR having merged in the meantime, a stale
branch), rebase again before reporting.

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

If a sibling repo's PR merged since the last time this ran (the human merged it
manually), rebasing onto the fresh `dev` here is still this skill's job — it's
the same operation regardless of who or what triggered the need for it.

### 7. Report, then stop

This is the end of the run. Do not open a check-run poll, do not call
`mcp__github__pull_request_read` in a loop, do not call
`mcp__github__merge_pull_request` — none of that is this skill's job. CI runs on
its own schedule once a PR is pushed; a human reviews it and merges (or asks for
another `/ship-work` pass) whenever they're ready. Report:

- every PR's URL, current base, and whether it's freshly opened or already existed
- the local gate results from step 3 (pass/fail per repo, and which command mirrored
  which CI job), since that's the only quality signal this run actually produced
- any rebase performed in step 6 and how conflicts (if any) were resolved
- for each repo, one line from **What CI actually checks** above, so the human
  reading the report knows what to expect without a separate lookup — e.g. "root
  has no PR-triggered CI, so there is nothing to wait for there"
- anything a hard stop caught, if the run ended early

Once a human has actually merged the PR(s), the closeout work below — Linear,
kata, the plan archive, worktree cleanup — still needs doing by someone, but not
autonomously by this run of the skill. See **After a human merges** below for what
that looks like; it's documented for reference, not executed here.

## After a human merges (reference — not run by this skill)

This section is retained so the closeout steps aren't lost, not because this
skill performs them. Once a PR from this ticket has actually landed on `dev`
(verified by a human, or by a later explicit request to close the ticket out):

- Linear → `Staging` for each merged repo, per `AGENTS.md` §2. Comment the PR URLs
  on the issue. **Never** set `Done`; a reviewer does that after verification.
- Archive the plan: `mkdir -p docs/plans/completed`, `git mv` it there, set
  `Status: Completed`. Mandatory per `AGENTS.md` §5. The plan lives in root, so
  fold this into the root PR when the ticket already has one. When it does not,
  open a small root PR carrying just the archive rather than pushing straight to
  `dev`.
- Close the kata issue (`kata search "ENG-<id>" --agent` to find the ref
  `/implement-issue` created in Phase A and kept open through Phase B): `kata close <ref>
  --done --message "<what shipped>" --commit <merge-sha> --agent`, one call
  per merged repo's commit if they differ, or the root's if only one applies.
  If kata is unavailable or the ref can't be found, note it and continue.
- Remove the worktree and local branch for the issue in every repo that merged —
  the same never-force rules as everywhere else: `git -C <repo> worktree remove
  <path>` (never `--force`) then `git -C <repo> branch -d <branch>` (never `-D`),
  and only once the branch is actually merged into its base and the worktree is
  clean. `autopilot/bin/ap-sweep.sh` (`ap sweep`) does exactly this check on a
  schedule for anything left behind — use it (`ap sweep --yes`) instead of
  hand-rolling the same check for the periodic cleanup case, or when cleaning up
  several issues' worktrees at once.

If asked to perform this closeout, verify the merge by content first (`git -C
<path> fetch origin dev --quiet && git -C <path> show origin/dev:<a-touched-file>
| grep <a-signature-line>`) — a 200 from a merge call or a green Linear status
are both consistent with a fix having been dropped by a race, same caution as
ever.

## Headless mode (--headless)

Shared vocabulary, `status.json` shape, the local queue contract, and the
ask→fallback rule live in `.claude/skills/autopilot-protocol.md` — read it
first; this section only states what maps to what for this skill.

Headless and interactive are now the same shape for this skill, because
neither one ever waits on CI or merges — there is no `--no-merge` to imply
anymore, since merging was never in scope to begin with. The only thing
headless mode changes is *how a stop or a success gets reported* (a local
queue write and `status.json` instead of a chat message).

Pushing feature branches and opening PRs against `dev` **is** pre-approved
under `--headless`, same as interactive — but the normal headless case is
that `/implement-issue --phase implement --headless` already did both as its
own step 13, so steps 4-5 here are the same fallback they are interactively.
Nothing else about the existing rules loosens: never `main`, never a direct
push to `dev` itself, never a merge call, and the only force-push is the
lease-guarded `git push --force-with-lease` in step 6's rebase, exactly as
interactive.

Each of the five **Hard stops** above, hit under `--headless`, ends the run as
`NEEDS_HUMAN` per the protocol's ask→fallback rule: record the stop reason
(which numbered hard stop, and the evidence — the review comment, the
conflicting diff, the finding string, the out-of-plan file list, or the
main/force-push/merge attempt) on the ticket and swap its state `shipping` →
`needs-input` (the wrapper already swapped `building` → `shipping` before
invoking this phase), in one write:
```bash
python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state needs-input \
  --field question='"<the stop reason + evidence>"' \
  --field phase_at_question='"ship"' \
  --event "hard stop: <short reason>"
```
Write `status.json` with `status: NEEDS_HUMAN`, `phase: "ship"`, and
`question` set to that same text. Also `kata meta set <ref> work.attention
needs-human --agent` and `work.attention_msg` to the same stop reason —
`/implement-issue`'s Phase B step 1 rule covers the mechanics; this is that
same signal, at this phase. Never continue past a hard stop headlessly — the
interactive rule ("stop, report, do not proceed to the next repo") holds
unchanged; headless mode only changes where the stop is reported.

**Success end state** (all local gates clear, PRs open and pushed, rebased
current): PR URLs — normally already recorded by `/implement-issue`'s own
`history` write at its Phase B step 13 — are (re)recorded on the ticket
alongside the local gate result, and the ticket's state is swapped
`shipping` → `ready-to-test`, in one write:
```bash
python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state ready-to-test \
  --field pr_urls='["<url>", ...]' \
  --event "ship done, local gates clean -> ready to test"
```
This is the write that used to be a PR-URL comment plus a `shipping` →
`ready-to-test` label swap — without it the ticket never leaves `shipping`
and a human running `ap sessions`/`ap status` never sees the finished work
surfaced, so do not skip it. On Linear — the one write beyond the claim, and
it is a label, not a comment — add label `agent:ready-to-test`; Linear status
stays `In Progress`. Headless ship-work never posts a Linear comment, success
or failure; the PR link(s) live on the ticket's `pr_urls` only. Never `Staging`
(that's the human's job once they've actually merged, per **After a human
merges** above) and never `Done`. Write `status.json` with `status: "DONE"`,
`phase: "ship"`, and `pr_urls` filled with every opened PR URL. Leave the kata
issue **open**, `work.attention ok` — this phase never merges, so it never
performs the post-merge closeout either; that stays for whichever later
request actually merges and asks for closeout.

Plan archiving (`docs/plans/` → `docs/plans/completed/`) does **not** happen
here — it's part of the post-merge closeout above, performed only once
someone has actually merged and asks for it.

**Never end the turn with required local work still in the background.** The
`-p` harness ends the process when your turn ends: there is no later turn in
which a background task's result comes back to you. This no longer applies to
CI (this skill never waits on it), but it still applies to step 3's local
gates and to anything else you'd be tempted to background inside this run:
run it in the foreground, or record state in `status.json` before yielding if
it genuinely cannot finish inside the turn.
