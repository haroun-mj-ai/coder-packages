---
name: implement-plan
description: Build an already-reviewed plan from docs/plans/ by dispatching Sonnet implementer agents per work unit, run the real quality gates, audit the tests against the spec, then QA beyond the happy path by deriving the change's blast radius and exercising the features it interacts with, commit, and run roborev. Writes the QA plan as a durable, committed artifact under docs/plans/qa/ carrying the gates' commit SHA and the exact relaunch commands, then stops any servers it started for its own verification rather than leaving them running — /test-issue starts the changed pair on demand later. Ends by recommending /ship-work; it never pushes, opens a PR, or merges. Use after the human has approved a plan, or on /implement-plan. Pairs with /plan-issue, which produces the plan. Do NOT use to design, to plan, or to root-cause a bug.
---

# implement-plan

Executes an approved plan. The design is settled before this skill runs; this
skill spends nothing on expensive inference except judgement.

## Usage

```
/implement-plan                                    # newest unarchived plan
/implement-plan docs/plans/2026-07-31-eng-123-foo.md
/implement-plan docs/plans/... --units U2,U3        # resume a partial build
```

## Why this shape

A Sonnet implementation of a settled spec lands at roughly the same fidelity as
an Opus one, for a fraction of the cost and several times faster, which means
reaching the failure mode sooner and having budget left to fix it. So:

- **Every work unit runs on `implementer`** (`subagent_type: "implementer"`,
  pinned sonnet + medium effort). Do not implement units yourself, and do not
  dispatch with an inline model override: the Agent tool accepts `model` but not
  `effort`, so an inline sonnet call still burns this session's effort level. The
  definition lives at `.claude/agents/implementer.md` and is loaded at session
  start; if the type is not found, ask for a restart rather than substituting.
- **You keep the judgement.** Reading implementer reports, deciding whether a
  flagged spec problem changes the plan, and running the quality gates are yours.
- **No review swarm.** One `implementer` per unit, and the deterministic tests are
  the review. `roborev` at the end is the second pass, once, on committed work.

## Instructions

### 1. Pre-flight

Read the plan file **in full**: it is the source of truth for everything below.

With no argument, look in the **root worktrees first**, since `/plan-issue` now
commits the plan there rather than leaving it untracked in the main checkout:

```bash
ls -t /home/coder/root-for-local/wt-eng*-root/docs/plans/*.md 2>/dev/null
ls -t docs/plans/*.md                                    # main checkout, older plans
```

Take the newest that is not in `completed/`, and confirm the choice with the human
before building it. The worktree the plan lives in is the worktree its root-repo work
belongs in.

Stop before doing anything else if:

- an open question is marked **BLOCKING** and unresolved: ask it and wait;
- the **Design review** section is missing, meaning the plan was never dry-run
  reviewed. Say so and offer `/plan-issue` on the ticket instead;
- the plan's `Status` is `Completed`.

Then check the working tree of every repo the plan touches, using absolute paths:

```bash
for r in . backend frontend assistants; do git -C "$r" status -sb; done
```

Uncommitted unrelated work in a target repo is a stop-and-ask, not something to
work around.

### 1a. Find out who else is working here

Concurrent Claude Code sessions on this repo are normal, not exceptional. Run
these in order of how much they actually prove:

```bash
git -C <path> worktree list                                  # hard fact
ls -lat ~/.claude/projects/-home-coder-root-for-local/*.jsonl | head   # heuristic
git -C <path> fetch origin <branch> --quiet && git -C <path> rev-parse HEAD origin/<branch>
git -C <path> status --porcelain                              # edits you did not make
```

- **`worktree list` is definitive.** Git refuses to check out one branch in two
  worktrees, so if your branch is already checked out elsewhere, that is settled:
  work in that worktree or make a new one. There are already around 19 worktrees on
  `backend/` and 3 on root.
- **The transcript mtimes are a heuristic.** A `.jsonl` touched in the last few
  minutes is another live session **on this project**. It does not tell you which
  branch or which repo that session is touching.
- **Remote drift** means someone else pushed to your branch. Never resolve that by
  force-pushing over them.

Be honest about the limit: **all four checks can come back clean while another
session edits a file you are about to.** So do not treat a quiet result as proof
you are alone. Treat a positive result as a reason to isolate, and prefer
isolating anyway (see 1c) when anything suggests company.

### 1b. Reuse the worktrees `/plan-issue` made, then rebase them

`/plan-issue` already fetched every repo and cut a worktree per involved repo off
fresh `dev`, named `wt-eng<id>-{root,be,fe}`. **Find them before creating anything.**
Two skills that both cut branches disagree about where the work lives, which is the
same class of bug as two skills that both push.

```bash
for r in . backend frontend assistants; do
  git -C "$r" worktree list | grep "wt-eng<id>-" && echo "  ^ reuse this"
done
```

Work in whichever exist. Only create one when `/plan-issue` did not: a plan written
before this convention, or a repo its scout missed. If you do create one, use the
same form, and **`--no-track` is mandatory** or the branch's upstream becomes
`origin/dev` and a bare `git push` later targets `dev` directly:

```bash
git -C <path> fetch origin --quiet
git -C <path> worktree add --no-track \
  /home/coder/root-for-local/wt-eng<id>-<suffix> \
  -b haroun/eng-<id>-<slug> origin/dev
```

`dev` above stands for whichever base 1e gives for that repo, which is `main` for
`assistants/` and `observability/`.

**A reused worktree must be verifiably fresh, or you do not reuse it.** Before
dispatching, for each worktree you plan to reuse, establish all three:

```bash
git -C <worktree> status --porcelain      # must be empty
git -C <worktree> log --oneline origin/dev..HEAD   # only the plan commit, if any
git -C <worktree> rev-list --count HEAD..origin/dev  # must be 0 after the rebase below
```

- **Empty and clean** (nothing uncommitted, nothing stashed, no commits beyond
  the plan) → rebase it onto fresh `origin/dev` and continue. For a genuinely
  empty tree that is identical to cutting a new one, so do the cheap thing.
- **Carries uncommitted work** → this is a previous run's unfinished
  implementation, not junk. ENG-1133 left **1465 uncommitted lines** in its
  backend worktree after being killed mid-build; recreating the worktree there
  would have destroyed a real, expensive build. **Stop** and report it
  (`NEEDS_HUMAN` headless) naming the files — a human decides whether to
  commit, stash, or discard.
- **Rebase does not come out clean** → stop, same as above. Do not force
  anything, do not delete the branch.

Never resolve staleness by deleting a worktree that has content. The only safe
recreate is of a tree with nothing in it.

**Rebase whatever you reuse, before dispatching anything.** A plan approved yesterday
sits on yesterday's `dev`:

```bash
git -C <worktree> fetch origin --quiet && git -C <worktree> rebase origin/dev
git -C <worktree> rev-list --count HEAD..origin/dev   # must be 0
```

Finding a conflict now costs one rebase. Finding it at ship time costs a rebase plus
a re-run of every agent that built on the stale tree.

Once a branch is pushed and has an open PR, a rebase needs `--force-with-lease`,
and must never happen while a merge is in flight. That race has silently dropped a
fix in this tree before. From that point on, `/ship-work` owns rebasing.

### 1c. Working in a worktree, including for browser QA

Worktrees are now the normal case rather than the exception, since `/plan-issue`
creates them. They also isolate you from the other live sessions on this checkout.

The one real hazard: **the dev server on 5173 and `python -m app.main` both serve the
main checkout**, so a change made in a worktree does not appear in the browser, and
step 7's QA will confidently verify unchanged code. A green screenshot of an app that
never changed is the most expensive outcome available in this workflow.

Do not respond by abandoning either the worktree or the QA. **Point a second server
at the worktree instead.** The recipe is already proven in this repo, documented in
the header of
`tests/e2e/tests/cockpit/cockpit-queue-detail-no-horizontal-clip.spec.ts`:

```bash
cd /home/coder/root-for-local/wt-eng<id>-fe
ln -s ../frontend/node_modules node_modules      # no second npm install
npx vite --port 5175 --strictPort
```

**The port must be 5173 to 5176.** `_DEFAULT_CORS_ORIGINS` at
`backend/app/main.py:98-101` admits only those four, and the app 404s without API
access, so an arbitrary high port produces a broken page that looks like a bug in
your change. Note it is `settings.BACKEND_CORS_ORIGINS or _DEFAULT_CORS_ORIGINS`
(`main.py:107`): if that env var is set locally it **replaces** the defaults, so check
it before blaming the port.

For a backend worktree, run its own `python -m app.main` from that tree, or accept
that API-level QA happens against the main checkout and say so in the QA plan.

A worktree of a gitignored sibling placed inside the root tree shows up as an
untracked directory in root's status, which is why root's status is full of `wt-*`
entries. **Never stage them.** Leave cleanup to `/ship-work` or to the human: the
worktree is where the branch lives until it merges.

### 1d. Stacking: only on a declared dependency

Stack on another branch when the plan **says** this work depends on it, or when the
unit demonstrably cannot compile or test without code that exists only there.
Otherwise branch off `origin/dev`.

**Do not stack merely because an unpushed branch exists.** This tree carries dozens
of local branches, most abandoned or unrelated, so inferring a dependency from
their existence is a coin flip, and a wrong guess is expensive in a way that hides
itself: the PR diff carries the parent's commits so reviewers read unrelated
changes as yours, CI validates the parent's code rather than the base, and if the
parent is later rewritten or dropped the child needs a `git rebase --onto` that
goes wrong quietly. If you suspect a dependency the plan does not declare, say so
and ask. That is a one-line question with a one-word answer.

When stacking is genuine: name the parent branch and its PR in the plan and in the
PR body, base the PR on the parent rather than `dev`, and state that it must not
merge first. After the parent lands:

```bash
git -C <path> rebase --onto origin/dev <old-parent-tip> <child-branch>
git -C <path> push --force-with-lease
```

Then verify by content, never by the command's output.

### 1e. Pick the base branch per repo

- root, `backend/`, `frontend/` → `dev`
- `assistants/` → `main`; it has no `dev` branch at all
- `observability/` → `main` is the trunk, though an `origin/dev` does exist

Do not assume: confirm with `git -C <abs-path> branch -a` before branching, since
these five repos do not share a branching convention.

Report the branch plan before creating anything. Creating a branch is fine;
committing is not.

### 2. Dispatch the work units

Group the plan's units by repo, then respect the dependency edges the plan
declares.

- **Sequential within a repo.** Two agents editing the same checkout will fight.
- **Concurrent across repos.** Backend and frontend are separate git repos and
  cannot conflict, so send their first units in a single message with multiple
  `Agent` calls. No worktrees needed, which is deliberate: the local dev server
  serves the main checkout's branch rather than a worktree, so worktree isolation
  actively breaks browser QA here.

Each `implementer` prompt must be self-contained, because the agent has not seen the
planning conversation and will not see the other units' reports:

- the unit's **spec verbatim** from the plan, including its test requirement and
  its "done when";
- the **absolute repo path**, and an instruction to use `git -C` for any git
  command;
- the exact file list, and that it is not to widen scope beyond it;
- the commands to run: for `frontend/`, `npm run build` and `npm run test:run`;
  for `backend/`, `poetry run pytest <the relevant path>`;
- the local-environment facts it would otherwise waste turns rediscovering:
  `poetry run` strips `PYTHONPATH` and the venv is at
  `/home/coder/root-for-local/.venv` (the *outer* tree, not `backend/`), so
  seed and one-off scripts run via that `.venv/bin/python` with an absolute
  `PYTHONPATH` rather than through `poetry run`; the local
  backend runs as `python -m app.main` with no hot reload, so a restart is needed
  after code or env changes;
- that it must **not commit, push, or open a PR**;
- relevant house conventions: MongoDB collection names are singular PascalCase
  matching the model class; every `DialogContent` carries the hidden-scrollbar
  classes; no `ENG-###` in code comments.

### 3. Escalate rather than letting the cheap model redesign

Read each report as it comes back. Trust it: the agent ran the tests and quoted
the output; do not re-read every changed file to double-check work that a passing
test already covers.

But when a report says the spec is wrong, a hook does not exist, or the change
does not fit: **stop that repo's chain and bring it here.** Decide yourself
whether the plan changes, amend the plan file if it does, and record the change
in its Design review section. An implementer improvising around a bad spec is the
exact failure this two-phase split exists to prevent.

### 4. Quality gates, run from this session

```bash
cd frontend && npm run build && npm run test:run    # TS check + build, unit tests
cd backend  && poetry run pytest
cd tests/e2e && npx playwright test                 # only if e2e specs changed
```

Report **verbatim output**. Never predict a result.

Two known noise sources, and baseline against untouched `dev` before attributing
either to this change:

- some backend endpoint tests fail in isolation with a pydantic `AttributeError:
  id` because Beanie was never initialized;
- roughly two dozen `test_specs_phase3` / `test_specs_phase4` failures are
  `assistants/` template drift, skipped in CI.

Note also that `ruff` is not blocking here and `dev` already carries substantial
lint debt. Match the neighbours, verify you added no new errors, and do not mass
reformat.

### 5. Audit the tests against the spec

Green tests and an implemented spec are two different claims, and everything above
only checks the first. Dispatch one `spec-auditor` (sonnet, read-only) with the
plan's behavior list, the diff, and the test files:

```bash
git -C <path> diff origin/dev...HEAD
```

For each behavior in the spec it answers: is it implemented, and **would a test
fail if it were removed?** That second question is the one nothing else in this
chain asks. It catches the two ways a green run lies:

- **a silently dropped behavior**: the unit specified five things, four got built
  and tested, the fifth is simply absent, and because no test was written for it
  every gate passes;
- **a tautological test**: one that restates the implementation rather than the
  rule, so it would pass for a wrong implementation too. The agent that wrote both
  the code and the test cannot see this, which is the entire reason for a separate
  pass.

Act on the verdict, do not just relay it:

- `MISSING` or `PARTIAL` behavior, and it is inside the plan's scope: send it back
  to an `implementer` with the specific behavior and the missing test.
- `TAUTOLOGICAL`: the test gets rewritten to assert the rule the spec stated. Do
  not accept "but it passes" as a defence.
- `UNVERIFIABLE`: legitimate. It goes into the QA plan's "needs a human" section
  with the reason, rather than being quietly dropped.
- **Behaviors in the diff the spec never asked for**: surface these. Unrequested
  scope is a human's call, and `/ship-work` will hard-stop on it later anyway.

This is one cheap dispatch and it is the only gate on the third point of truth, so
do not skip it because the tests are green. Green is the input to this step, not a
substitute for it.

### 6. Derive the blast radius before doing any QA

The happy path is the easy half and the tests already cover it. What breaks in
production here is **interaction**: something else reads the same data, renders in
the same shell, or shares the same cache, and nobody thought to look. You cannot
brainstorm your way to that list, because you only know the feature you just
built. Derive it instead.

Dispatch a `scout` (haiku, cheap) with the actual diff and ask for a flat list:

```bash
git -C <path> diff --stat origin/dev...HEAD          # give scout the real surface
```

For every function, component, hook, endpoint, model field, query key, and context
value the diff touched, scout returns **every other call site and consumer** with
`path:line`. That list is the QA surface. Anything on it that the tests do not
cover gets exercised by hand.

Then check the change against the failure classes this codebase actually produces.
These are not hypothetical; each has shipped a real bug here:

- **Tenancy isolation.** Routes are `/o/:orgId/w/:workspaceId/s/:sessionId`, so
  every feature has org and workspace scoping. Verify: data from one workspace
  never appears in another, switching org mid-flight does not serve stale data, and
  a user without access gets nothing rather than an empty shell. Cross-workspace
  and org-wide visibility leaks are a **repeat** failure class here, so if the
  change reads or writes anything tenant-scoped, this is mandatory, not optional.
- **Permissions and role.** Manager against rep against staff. A read-only path
  that silently no-ops looks identical to success.
- **Real-time.** WebSocket plus Redis pub/sub. Reconnect after a drop, a stale
  token on the socket, an event arriving for a different session, two tabs open on
  the same session.
- **Empty, single, and overflowing.** Zero items, exactly one, and past whatever
  cap exists (several lists here load to a 100 cap). Long strings, long names, long
  subjects. First-run state before any sync has happened.
- **Failure and latency.** The request 500s, the integration is not connected, the
  sync has not run yet. Loading and error states are where UX gaps hide, because
  nobody designs them.
- **Layout at real widths.** The last two tickets in this repo were horizontal
  clipping and banner layout. Check narrow and wide, and assert no horizontal
  overflow on the page body.

If the change touches a TanStack Query key or a context provider (auth, WebSocket,
streaming, theme), treat every consumer scout found as in scope. A changed cache
key serves stale or wrong data to views that were never edited, which is the
hardest class of bug to attribute later.

### 7. QA against that surface, in the browser when `frontend/` changed

Drive the running dev server with the Playwright MCP tools and capture screenshots
as `qa-<ticket>-NN-<what>.png`. Two things that will otherwise cost you an hour:

- **The dev server serves the main checkout's branch**, not a worktree. Confirm
  which branch is actually being served before trusting what you see.
- **Browser sessions from a minted token get logged out.** Log in with the real
  test credentials in the global instructions, or verify the data by curling the
  REST endpoint directly.

A passing Playwright step is weak evidence on its own: it will click a button that
is behind another button and report success. So assert what a click cannot:

- the element is genuinely visible and not occluded, not merely present in the DOM
- the page body does not scroll horizontally
- the state **after** the interaction is what the plan promised, read back from the
  UI or the API rather than assumed
- the neighbouring features scout listed still behave, not just the new one

**The layout assertions are already written. Use them.**
`tests/e2e/lib/layout-assertions.ts` exports `expectNoHorizontalClipping`,
`expectNotOccluded`, `expectTruncated`, and `measureLayout`. They take real
geometry measurements in a real browser, which is the one thing neither `jsdom`
nor a DOM query can do. A new or changed view gets these in its e2e spec rather
than a hand-rolled measurement, and `expectTruncated` is the positive control:
without it, a clipping assertion can pass simply because the element was never
width-constrained.

Note what Playwright already covers so you do not duplicate it: `locator.click()`
performs a hit-target check and fails when something covers what you are clicking.
The gap is everything you never click, a badge or a heading or a count, and it is
also every kind of overflow, which Playwright never checks at all.

`npm run test:selftest` in `tests/e2e` proves those helpers still bite, and needs
no backend, no frontend, and no auth.

**Anything you find here that a test could have caught becomes a test.** A manual
QA pass that discovers an interaction bug and fixes it without leaving a spec
behind guarantees the same bug returns. That is the whole reason the tests exist as
a separate point of truth from the code.

For backend-only changes there is no browser, but the surface is the same: exercise
the other call sites scout found, with the tenancy and permission cases above,
against the local API.

### 8. Write the QA plan as a durable artifact

The plan the human runs before this reaches staging — and, from now on, the one
artifact `/ship-work` and `/test-issue` read instead of re-deriving what this
step already computed. Reporting it only in this chat's transcript and in an
inbox comment meant `/test-issue` had to re-run the blast-radius derivation and
re-discover the gate results from scratch; the whole saving of computing them
once here was lost the moment they were never written anywhere durable.

Write it to `<root-worktree>/docs/plans/qa/<eng-id>-qa.md` (create the `qa/`
directory if it does not exist yet). Start the file with a machine-readable
header, in this exact order and these exact keys:

```
Issue: ENG-<id>
Commit: <the SHA step 4's gates were run against, one per touched repo, e.g. "backend abc1234, frontend def5678">
Gates: <verbatim pass/fail summary per gate command, e.g. "frontend build+test:run PASS, backend pytest PASS">
Relaunch: <exact commands to bring the changed pair up on demand — worktree paths, ports, the .env.local copy, the node_modules symlink, and the 5173-5176 CORS window caveat; see step 11>
PRs: (filled in by ship-work)
```

Below the header, the same four-section body as before:

1. **Verified here**, with the evidence: what was run or clicked, and the result.
2. **Needs a human**, and why the agent could not reach it. Be specific rather than
   vague, because a vague gap gets skipped: CRM objects are `read_only` locally so
   writes cannot be exercised, an integration has no local credentials, a cron has
   not fired, staging data differs.
3. **Interaction cases from the blast radius**, named individually with the feature
   that could break, not summarised as "check related features".
4. **The edge cases from the plan**, plus any the QA pass added.

Assume the app is live and a regression is visible to customers. State plainly what
was **not** covered; an honest gap is useful and a silent one is a trap.

Commit the artifact in its own commit on the plan's branch, subject
`ENG-<id>: add QA plan artifact` — do not fold it into a work-unit commit. It is
computed after every unit has already landed and been audited, so it never
shares a reason with an earlier commit, and giving it a dedicated commit means
`/ship-work`'s later one-line edit to the `PRs:` line (see `ship-work/SKILL.md`
step 5) touches a file nothing else is mid-editing. Stage it with the explicit
path, same as step 10's rule.

Still surface it beyond the file, as before: report it in this session's chat
(step 9), and in headless mode post its header and a one-line pointer to the
inbox issue, marked `Phase: implement` per the protocol's marker rule (an
informational note, not a `NEEDS_HUMAN` question) — but the **file is the
source of truth**; the inbox post and the chat report are courtesy copies of
it, not the other way around. Headless runs additionally record the artifact's
absolute path in `status.json`'s `detail`, so the morning review opens it
directly instead of hunting for it.

### 9. Stop and report

Report, high level first:

1. What was built, per work unit, and the files changed with a one-line reason.
2. Verbatim test and build output.
3. Screenshots taken, if any.
4. The QA plan.
5. **Anything not implemented, and precisely why.** If part of the plan was
   blocked, everything else is still finished. Say plainly what was left out.
   Scaling the work down is the human's call.

Do **not** ask for approval to commit or to run roborev. Neither leaves the
machine and both are trivially reversible, so gating them is pure friction. What
still needs explicit approval is anything others can see: pushing, opening a PR,
merging, and Linear writes. Those belong to `/ship-work`.

### 10. Commit, then review

Commit with subject `ENG-<id>: <what changed>`, one coherent unit per commit:

- stage with **explicit paths**. Never `git add -A`: it has leaked live secrets
  from this tree before;
- use `git -C <abs-path>` per repo;
- trailers: **only** the human's two `Co-Authored-By` lines, after a blank line.
  Never an assistant or Claude co-author trailer. The tracked `commit-msg` hook
  (`scripts/hooks/commit-msg`, wired by `scripts/install-hooks.sh`) adds both
  idempotently and strips assistant trailers, so local commits are covered and
  typing them anyway is harmless. It does **not** fire for commits made through
  the GitHub API or web UI — write them by hand there. Either way verify with
  `git -C <path> log -1 --format=%B` rather than assuming;
- small fixups on an unmerged branch of the human's own get `--amend`, not a
  follow-up "fix" commit. The amend itself is free; if the branch was already
  pushed, the `--force-with-lease` that follows is a push and needs approval like
  any other.

Then run the second review pass on committed work:

```bash
roborev review --branch --base origin/dev --wait --repo <abs-repo-path>
```

Note the flag form: the subcommand is `review`, `--branch` is a flag, and
`--repo` targets a sibling repo without a `cd`. Pass `--base` explicitly rather
than letting it auto-detect, since branches cut from a remote ref otherwise get
reviewed against a stale local base. For `assistants/` use `--base origin/main`.

No `--agent` or `--model` flag is needed: roborev's global config pins every
review purpose to `claude-code` with `sonnet`. Do not pass a more expensive model
on the command line, which would put the review back on the tier this whole chain
exists to avoid.

Exit code 1 means the verdict was Fail, i.e. there are findings, not a
crash, so read the output before reporting an error. Present the findings and
offer `/roborev-fix`. Note that roborev only sees the committed branch of one
repo, so its cross-repo findings about the gitignored siblings are usually noise:
verify the frontend yourself rather than looping on them.

### 11. Stop what you started; record how to relaunch it

This step used to end with four servers left running — changed frontend and
backend plus an unchanged `dev` baseline — on the theory that a human was about
to sit down and click through the diff. Under autopilot that theory is false:
a headless build routinely finishes at 3am and the human looks at 9am, by which
point those processes are either dead (the workspace recycled, the shell that
spawned them gone) or stale (serving a commit six rebases old), and the ports
they squatted bought nothing. Interactive runs have the same problem in miniature
whenever the human steps away between the build finishing and the review
starting. So: **implement-plan no longer leaves servers running for handover,
in either mode.**

What changes in practice:

- Whatever you started for step 7's own QA (the worktree frontend on its
  5173–5176 port, and a worktree or main-checkout backend per 1c) gets stopped
  once that QA is done, in this same step. Verify the stop actually happened
  with `ss -ltnp` before and after, the same way headless mode already did.
- **Never touch the baseline pair (5173/8000).** This step never starts it —
  it is shared, long-running infrastructure that predates any single run — so
  there is nothing of yours to stop there. If you needed a baseline comparison
  during step 7, you read against whatever was already serving those ports;
  you did not spin up a second one.
- Instead of a live server, what gets handed over is the **exact relaunch
  recipe**: worktree paths, ports, the `.env.local` copy into the worktree
  backend, the `node_modules` symlink for the worktree frontend (no second
  `npm install`), and the 5173–5176 CORS-window caveat
  (`_DEFAULT_CORS_ORIGINS`, `backend/app/main.py:98-101` — a frontend outside
  that range 404s its API calls and renders a broken page that reads as a bug
  in the change). Write this recipe into the QA artifact's `Relaunch:` header
  from step 8 — that is its only home; do not also try to keep it fresh in
  chat, since chat is exactly the transcript this whole fix moves work out of.

`/test-issue` is what starts the changed pair later, on demand, reading that
same `Relaunch:` header rather than guessing the ports and paths anew. That
handoff is the point: the process that will actually be clicked is started
minutes before it is used, by the session that is about to use it, instead of
hours early by a session that has already left.

### 12. Hand off to `/ship-work`, and do not push

This skill ends at a committed, roborev-reviewed branch and **stops there**.

**Never push. Never `git push`, never `--force-with-lease`, never open or update a
PR, never merge, never archive the plan, never move the Linear status.** Not even
when the branch is obviously ready, not even when the human said "push" earlier in
the conversation about a different batch, and not even if a step above left the
branch feeling incomplete. Everything past the commit belongs to `/ship-work`,
which owns rebasing onto fresh `dev`, waiting on the real CI checks, the fix
budget, and landing the PRs in dependency order.

Two skills that both push are two skills that disagree about what state the branch
is in, so the seam is deliberate: commit here, because roborev needs committed
work; ship there.

**End every run by recommending the next command**, with the plan path filled in:

> Implementation is committed on `<branch>` in `<repos>` and roborev is clean.
> QA artifact: `docs/plans/qa/<eng-id>-qa.md` (commit `<sha>`, gates `<pass/fail>`).
> No servers were left running — the changed pair's relaunch commands are in the
> artifact's `Relaunch:` header for `/test-issue` to use on demand.
> Nothing has been pushed. Run `/ship-work docs/plans/<plan>.md` to open the PRs
> and land it on `dev`.

Say it even when the run stopped early, adjusted for what is actually left: if a
work unit is blocked, name what remains and say that `/ship-work` should wait
until it is resolved. A run that ends without pointing at the next step leaves the
human guessing whether the work is shippable.

### Local environment facts for this workspace (autopilot and interactive)

These cost two runs ~$10 to rediscover and were both misdiagnosed; do not
re-derive them.

- **Databases are not on `localhost`.** The docker daemon belongs to the host,
  so published container ports are reachable via `host.docker.internal` (the
  bridge gateway), never `localhost`. The populated stack is
  **mongo `host.docker.internal:27018`** and **redis `:6380`** — the plain
  `mongodb`/`redis` containers on 27017/6379 hold an EMPTY `journeyai` db.
  `backend/.env.local` points at the right ones as of 2026-08-12.
- **Native libs need `LD_LIBRARY_PATH`.** `import numpy` fails with
  `libz.so.1: cannot open shared object file` (it is zlib, NOT libstdc++),
  which cascades through `qdrant_client` → `grpc` and makes `app.main`
  unimportable. `autopilot/bin/ap-env.sh` exports the discovered zlib and
  gcc-lib paths, so autopilot acts already have it.
- **Export the env file, don't just rely on it.** `OPENAI_API_KEY` is read from
  the raw environment rather than pydantic settings, so a local run needs
  `set -a; . ./.env.local; set +a` — and the file must be LF, not CRLF.
- **Verified working recipe** (from the backend dir): export the env file,
  ensure `LD_LIBRARY_PATH`, then `poetry run pytest <paths> -q --no-cov`. A
  single-file run otherwise trips the repo-wide 40% coverage gate, which is the
  threshold talking, not your change.
- **Playwright is available** — chromium is installed and `mcp__playwright__*`
  is allowed in the autopilot profile. Browser QA is expected, not optional.

## Headless mode (`--headless`)

Shared vocabulary, `status.json` shape, the inbox contract, and the
ask→fallback rule all live in `.claude/skills/autopilot-protocol.md` — read it
first. This section only states what this skill's own ask points map to under
that protocol.

This skill's `NEEDS_HUMAN` inbox comments start with the line `Phase:
implement`, per the protocol's ask→fallback rule.

**Plan path is always explicit.** Step 1's "newest unarchived plan" inference
and "confirm the choice with the human before building it" are interactive-only
— autopilot always calls this skill with a concrete plan path. A headless
invocation with no explicit plan path argument writes `status.json` with
`status: FAILED` and `detail: "headless requires an explicit plan path"`, and
ends without touching the inbox (there is nothing yet to attach the failure
to).

**Step 1's stop conditions**, mapped per the protocol's ask→fallback rule:

- **Open question marked BLOCKING and unresolved** — no documented default
  exists, so this is fallback case 2: post the question to the inbox issue,
  set `status: NEEDS_HUMAN`, `question` the exact BLOCKING text.
- **Design review section missing** — this is not an ask with a fallback; it
  means the plan was never dry-run reviewed, and no headless run can perform
  that review. `status: FAILED`, `detail: "plan was never dry-run reviewed; a
  human must re-plan"`. Do not attempt the review yourself and do not fall
  back to `NEEDS_HUMAN`: a missing Design review is a planning defect, not a
  question a `go`/feedback comment can resolve.
- **Uncommitted unrelated work in a target repo** — never work around it.
  `status: NEEDS_HUMAN`, with the exact `git status -sb` output for that repo
  quoted in the `question` posted to the inbox, so the owner sees precisely
  what is in the way.

**Step 3's escalation** — when an implementer report says the spec is wrong, a
hook does not exist, or the change does not fit: do not redesign around it,
headless or not. Stop that repo's chain, `status: NEEDS_HUMAN`, and post the
report's finding verbatim as the `question` on the inbox issue. The plan is
never amended headlessly; that judgement call stays with the human, same as it
would be blocking in an interactive run.

**Server policy (step 11).** Run the full QA described above, including the
comparison against the baseline pair, exactly as interactive mode does —
headless QA is not lighter QA. Once QA is done, stop the **changed-pair**
servers this run started for it (the worktree frontend's `vite` process and
the worktree backend's `uvicorn`/`python -m app.main` process); the baseline
pair (5173/8000) is never something this run started, so there is nothing of
yours to stop there either way. Write the exact commands to bring the changed
pair back up — worktree paths, ports, and the literal `vite`/`uvicorn` command
lines used — into the QA artifact's `Relaunch:` header, same as interactive
mode (step 8/11); that is the durable copy. Then record the **artifact's
absolute path** (not a second copy of the commands) in `status.json`'s
`detail`, and post the same path as a comment on the inbox issue prefixed
`Phase: implement` per the protocol's marker rule, so the owner's morning
review opens one file rather than reassembling commands from two places.
Verify the teardown actually happened with `ss -ltnp` (before/after, or
immediately after stopping) and note the result in `detail`; a server left
bound defeats the point of this whole step.

**`--ports fe=<n>,be=<m>` overrides the port range above.** The orchestrator
runs several build slots concurrently (`AP_BUILD_SLOTS`), each with its own
port pair, and hands the assigned pair to this invocation as literal prompt
text — the same mechanism as `--run-dir`, and for the same reason: the
`dontAsk` profile is path-scoped, so the session cannot read it from env.
When `--ports` is present, bind the changed-pair frontend and backend to
**exactly** those two ports, `fe=<n>` for `vite --port` and `be=<m>` for the
worktree `uvicorn --port`, instead of 1c/step 11's 5173–5176 range — and
**never** to the baseline pair (5173/8000), even if `--ports` happens to
name a port inside that historical range. Start the worktree backend with
`BACKEND_CORS_ORIGINS` set to a JSON list containing at least
`http://localhost:<feport>`, e.g.
`BACKEND_CORS_ORIGINS='["http://localhost:<feport>"]' uvicorn app.main:app --port <beport>`
— per `backend/app/main.py`'s `settings.BACKEND_CORS_ORIGINS or
_DEFAULT_CORS_ORIGINS`, setting this env var **replaces** the default
allowlist rather than extending it, which is exactly what lets a `--ports`
pair outside 5173–5176 work at all; omitting it here is the same broken-page
failure 1c warns about, just for a different port range. The teardown rule
is unchanged either way: stop the changed pair after QA, leave the baseline
alone, and write the relaunch commands with the actual ports used into the QA
artifact's `Relaunch:` header.

**End state.** Commit exactly as interactive mode does (step 10: explicit
paths, only the human's `Co-Authored-By` trailers), and run `roborev` exactly
as interactive mode does. Then write `status.json` with `status: DONE`,
`phase: "implement"`, and `plan_path` set to the plan file's absolute path.
Do **not** change the inbox issue's label — it stays `building`; the ship
phase that runs in the same cycle owns the next transition (`ready-to-test` or
`failed`). Roborev findings never block a `DONE` write: record them in
`detail` so the interactive morning review sees them, same as any other
relaunch note.

**The push rule is unchanged.** Step 12's "never push, never open or update a
PR, never merge, never move the Linear status" applies identically in
headless mode. Headless `/implement-plan` still stops at a committed,
roborev-reviewed branch; pushing and PRs belong to `/ship-work`, headless or
not.

**Never end the turn with work still in the background.** The headless `-p`
harness kills the session outright once its background-wait ceiling passes —
no final message, no `status.json`, and the wrapper reconciles the run as a
crash even when every gate was green. So in headless mode: run the quality
gates as **blocking foreground commands** (never parked as background tasks
you "wait on"), and treat writing `status.json` as a step that must complete
before anything else is allowed to still be running. If a long suite
genuinely must run in the background, write an interim `status.json`
(`FAILED`, detail "gates still running at turn end") first and let the
retry recover — never leave the file unwritten while waiting.
