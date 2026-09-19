---
name: test-issue
description: Walk the human through testing one ready-to-test issue end to end — assemble its PRs across repos, stand up the changed-vs-baseline comparison, run the e2e spec and browser QA, then hand over the merge command for the human to run themselves. Interactive only, a human's own QA session, not headless. Use when an issue's PRs are open and need verification before merge. Do NOT use to write feature code, and do NOT use to merge — nothing in this pipeline merges autonomously, that's always the human's own action.
---

# test-issue

Turns `docs/qa-runbook.md` into a run, not a read. This skill does the assembling
and the mechanical checking; the human still does the judging that only a human
can do — whether a screenshot actually looks right, whether a UX gap matters.

**Not this skill's job:** writing or fixing feature code (that is `/implement-issue`,
or a direct fix if something is broken), and merging — nothing in this pipeline
merges autonomously; the human runs the merge command themselves once they're
satisfied. If testing turns up a real bug, report it and stop — do not silently
patch it here.

## Usage

```
/test-issue ENG-1135
/test-issue next     # oldest local queue ticket at state ready-to-test
/test-issue          # same as next
```

## Instructions

### 1. Read the QA artifact first — do not re-derive what it already computed

If given `next` or no argument, list the local queue (`ap sessions`, or
`python3 "$QUEUE_PY" --ap-home "$AP_HOME" list --state ready-to-test` — see
`.claude/skills/autopilot-protocol.md`'s "Local queue contract" for how to
resolve `$QUEUE_PY`) and take the oldest by `seq`.

`/implement-issue`'s Phase B already wrote a durable QA artifact for this issue at
`docs/plans/qa/<eng-id>-qa.md` in the root worktree, and `/ship-work` already
filled in its `PRs:` line once the PRs were open. Read that file **before**
touching `gh` at all:

- `PRs:` gives the PR list per repo directly — no `gh pr list` search needed.
- `Relaunch:` gives the exact commands to bring the changed pair up — worktree
  paths, ports, the `.env.local` copy, the `node_modules` symlink, and the
  CORS-window caveat — so step 3 below is a copy-paste, not a rediscovery.
- The four QA sections (**Verified here**, **Needs a human**, **Interaction
  cases from the blast radius**, **Edge cases**) are this skill's checklist.
  **Your job in steps 4–6 is to execute that checklist, not to re-derive it.**
  Do not re-run the blast-radius derivation (`/implement-issue`'s Phase B
  step 7 already dispatched a `scout` for this and paid for it once) — walk the **Needs a
  human** and **Interaction cases** sections item by item instead. Items
  already marked **Verified here** get spot-checked at most — pick one or two
  to confirm the artifact's claim still holds, do not repeat the whole list
  wholesale; repeating work that already has evidence is the exact
  duplication this fix removes.

**Fall back to the old `gh`-search path only when the artifact is missing, or
exists but has no `PRs:` line** (an older plan predating this convention, or a
partially-written artifact):

```bash
for r in journeyai-backend frontend root-for-local; do
  gh pr list -R JourneyAI-Team/$r --json number,headRefName \
    --jq ".[]|select(.headRefName|test(\"eng-<ID>\"))|\"$r #\(.number)\""
done
```

**The root PR is usually docs-only and is NOT the change.** Do not mistake it for
one of the code PRs — it carries the plan doc, runbooks, and any e2e spec, and its
absence of a frontend or backend diff is expected, not a red flag.

If the artifact itself is missing entirely, also read the plan file (its path is
either the queue ticket's `plan_path` field, or the newest matching
file in `docs/plans/` in the root worktree) and pull its **Verification** and
**Interaction surface** sections as the fallback checklist — this is the same
information the artifact would otherwise have carried forward.

**Classify the issue** before doing anything else:

- **Backend-only**: no frontend PR exists for this issue. No servers to eyeball,
  everything is curl.
- **UI issue**: a frontend PR exists. Needs the side-by-side browser comparison.

State the classification out loud, along with the PR numbers found and the worktree
paths (`wt-eng<ID>-{be,fe,root}`), before moving on.

**Check drift against the base branch. Never rebase.** For each repo the issue
touches:

```bash
git -C <worktree> fetch origin --quiet
git -C <worktree> rev-list --count <branch>..origin/dev   # origin/main for assistants/observability
```

Report the number per repo:

- **Zero** — say so and continue; the comparison is clean.
- **Nonzero** — report it prominently, before anything is stood up. The baseline
  (the main checkout, sitting on `dev`'s tip) then contains commits the branch
  does not, so a difference between the two panes is no longer attributable to
  this change alone — it might just be `dev` having moved. Tell the human exactly
  what they would be comparing, and let them decide whether to test anyway or wait
  for a rebase.

Also run a non-mutating conflict probe, so a merge conflict is found before 20
minutes of QA rather than at merge time:

```bash
git -C <worktree> merge-tree --write-tree origin/dev <branch>
```

(On an older git without `--write-tree`, use the three-arg form:
`git -C <worktree> merge-tree "$(git -C <worktree> merge-base <branch> origin/dev)" <branch> origin/dev`.)
Report whether it would conflict. Do not create a commit, do not check anything
out — this command only asks the question, it never writes.

**Never rebase these worktrees, and do not let a later pass talk you into it:**

- The branch is pushed and has an open PR. A rebase means a
  `--force-with-lease` push — a **write** to a PR that may be under human
  review, and it restarts CI. `/test-issue` is a read-only QA session; it has no
  business mutating a reviewable branch.
- `/ship-work` already owns rebasing (see its rebase step). Two skills that both
  rebase the same branch can disagree about what state it is in — exactly the
  class of bug the plan/build/ship seam exists to avoid.
- If you rebase and something then fails, you can no longer tell "the change is
  broken" from "the rebase broke it." Reporting drift and letting `/ship-work`
  resolve it keeps those two questions separate.

If drift or a conflict is found, the handoff in step 7 says to run `/ship-work`
(which rebases properly and waits on CI) — never suggest a manual rebase here.

### 1b. Root-cause & surface coverage audit

This is what turns "the tests pass" into "I'm confident this closes the root cause
and nothing else shares its defect." It is cheap and deterministic — pure git/grep,
no servers — so it runs here, before step 2's preflight, not bolted on at the end.

**Read the issue's own investigation artifact**, whichever kind this issue has:

- **Bug path**: `docs/issues/issue-<ENG-ID>.md` (the RCA, root repo) — pull its
  **Evidence Chain (5 Whys)**, **Files to Modify**, and **Adversarial Review**
  sections. Also read `docs/issues/reports/<ENG-ID>-fix-report.md` if it exists — the
  implementer's own account of what it did and any deviations. Read it for *claims*,
  not proof; every check below re-verifies those claims against the real diff rather
  than trusting the narrative.
- **Feature path**: the plan doc (`docs/plans/*.md`) — pull its **Relevant Codebase
  Files** / **New Files to Create** and **Adversarial Review** sections instead.

Four distinct checks. Keep them distinct in your notes and in step 6's verdict too —
each answers a different question, and folding them into one bucket lets a PR that
passes one hide a failure on another (a diff that does exactly what the RCA asked
can still miss a surface the RCA never knew to ask about; that is not a lesser
version of the same finding, it is a different, worse one).

**1. Root-cause coverage — does the diff do what the artifact said to do?**

```bash
gh pr diff <PR#> -R JourneyAI-Team/<repo> --name-only
```

For every file the artifact names as needing a change:
- **Present in the diff** — fine, move on.
- **Absent from the diff** — find the artifact's own words for why (a "Decision"
  section redirecting scope, an explicit "out of scope"/"descoped" callout, a
  follow-up ticket named). If one exists, quote it in your report. **If none
  exists, this is a real gap** — a location the investigation itself said needed to
  change, that nothing changed. Report it prominently; a silent omission is not the
  same as a documented descope, and only the latter is safe to merge past.

A file the diff touches that the artifact never named needs only a one-line reason
(a new test file, a docstring) — but unexplained production logic there is worth
asking about, since it means the artifact's own root-cause scope may be incomplete.

**This check is bounded by the artifact's own imagination — it can only confirm the
PR covers what the RCA thought to name.** It cannot tell you the RCA missed
something entirely; that is check 2's job, not this one, and a clean result here
says nothing about whether check 2 is also clean.

**2. Surface coverage — did the investigation itself fail to name a location that
actually shares the defect?** This is a different question from check 1 and does
not follow from it: check 1 asks "did the fix do what the RCA specified," this asks
"did the RCA specify enough in the first place." Do not skip this because check 1
came back clean — a clean check 1 on an incomplete RCA is exactly the failure mode
this check exists to catch.

Grep the *symbol* or *anti-pattern* the root cause centers on (a field name, a
function, the specific missing guard or comparison) — not the ticket number, and
critically, **not limited to the files the artifact already discusses**:

```bash
grep -rn "<the field/function/pattern the root cause centers on>" --include='*.py' <repo>
```

Sort every hit into one of three buckets: touched by this diff; named by the
artifact as known-and-descoped (quote it — a location the RCA *named and chose not
to fix* is a documented decision, not a miss); or **neither** — a location the RCA
**never mentioned at all**, that the pattern still reaches. That third bucket, and
only that third bucket, is a surface-coverage finding. A full-repo grep costs
seconds; a sibling call site the investigation never knew about is exactly what
comes back as a new ticket two weeks after everyone thought this was closed.

**3. Adversarial-review test backing — does every must-preserve case actually have
a test, or just a claim?** If the artifact's **Adversarial Review** section names a
must-stay-suppressed/must-not-regress case, a discriminator attack, or a boundary a
red-team/challenge pass insisted on (a timezone grace day, a null-fallback, a
specific ordering, a case that must keep failing) — grep the diff's test files for a
test whose name or docstring actually matches that scenario. A must-preserve case
with no matching test is one that can regress silently on the very next refactor;
name it explicitly rather than assuming the artifact's prose is enough on its own.

**4. Mutation spot-check — did you watch a claimed test actually catch its
regression, or only read that it does?** If the report claims mutation testing was
done, don't take "reverted it, confirmed the test failed by name, restored it" on
faith — reproduce it once yourself, for the single most load-bearing change
(usually the exact line the root cause centers on):

```bash
git -C <worktree> stash push -u -m "test-issue-mutation-check-<ENG-ID>"
# hand-revert the one line/guard the report claims is load-bearing
poetry run pytest <the test file it claims covers it> -k <test name> -v   # must FAIL
git -C <worktree> stash list --format='%H %gs'   # find your entry by its tag
git -C <worktree> stash apply <that sha>                                  # never a bare pop
poetry run pytest <same test> -v                                          # must PASS again
git -C <worktree> stash drop <that sha>
```

Ten minutes here is the difference between "the implementer says the test is
meaningful" and "I watched it fail for the right reason" — and it is the strongest
single piece of evidence you can hand yourself before merging.

Carry all four into step 6 as four separate lines, not one bucket — don't wait
until then to write any of it down; capture findings as you go.

### 2. Environment preflight

Cheap and deterministic — do this before anything that costs money or time. If
anything here is down, **say so and stop.** Do not attempt repairs beyond what
`ap-env.sh` already does; a broken local environment is not this skill's problem to
fix.

```bash
source /home/coder/coder-packages/autopilot/bin/ap-env.sh
```

Then check reachability of the two databases (plain `localhost` — the Coder
template uses host networking as of 2026-08-13):

```bash
nc -zv localhost 27017   # mongo
nc -zv localhost 6379    # redis
```

And check whether the baseline ports (5173 frontend, 8000 backend) are already up —
this determines whether step 3 starts a baseline or reuses one:

```bash
ss -ltn | grep -E ':(5173|8000)'
```

### 3. Stand up the comparison

Use the QA artifact's `Relaunch:` header from step 1 to bring the changed pair
up — it names the exact worktree paths and ports `/implement-issue`'s Phase B used, so
this is a copy-paste rather than a rediscovery. Fall back to the runbook's
Step 1 (same recipe, by convention fe 5174+/be 8001+) only when the artifact
was missing or had no usable `Relaunch:` line. Baseline stays on 5173/8000,
reused if already running rather than restarted, either way.

**Backend-only issues skip the frontend half of this step entirely** — there is
nothing to compare visually, so no `npx vite` for either side.

```bash
# $AP_WORK_REPO: this repo's absolute path (set by ap-env.sh; default
# /home/coder/root-for-local, but never hardcode it -- differs per machine).
# BASELINE (unchanged dev) -- check first, only start if not already up
cd "$AP_WORK_REPO/frontend" && npx vite --port 5173 --strictPort &
cd "$AP_WORK_REPO/backend"  && poetry run uvicorn app.main:app --port 8000 &

# CHANGED (this issue's worktrees)
cd "$AP_WORK_REPO/wt-eng<ID>-fe"
ln -s ../frontend/node_modules node_modules      # no second npm install
npx vite --port 5175 --strictPort &

cd "$AP_WORK_REPO/wt-eng<ID>-be"
cp ../backend/.env.local .env.local              # worktrees have no env file
poetry run uvicorn app.main:app --port 8002 &
```

**CORS window is 5173-5176.** The backend's default `BACKEND_CORS_ORIGINS` admits
only that range (`_DEFAULT_CORS_ORIGINS`, `backend/app/main.py`). A frontend outside
it renders a broken page that looks exactly like a bug in the change but is not
one. Stay inside the window or set `BACKEND_CORS_ORIGINS` explicitly for the
backend you start.

### 4. Exercise it

**Backend-only:**

```bash
# form-encoded, OAuth2 style -- JSON gets a 422
curl -s -X POST http://localhost:8002/api/v1/auth/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'username=<you@meetjourney.ai>' \
  --data-urlencode 'password=<password>'
```

Then hit the same endpoint on 8000 (baseline) and 8002 (change) with the same
inputs and diff the two responses. The diff itself is the evidence, not a
paraphrase of it.

**UI issue:**

Drive the real user path with the Playwright MCP tools (`mcp__playwright__*`)
against **both** ports — do not eyeball one side and assume the other. Log in with
the real test credentials. For each screen you touch, screenshot both sides as
`qa-<ENG-id>-<nn>-<what>.png` (e.g. `qa-eng1135-01-feed-view.png`,
`qa-eng1135-01-feed-view-baseline.png`), and assert explicitly:

- the change is present and correct on the changed port (5175)
- the change is **absent** on the baseline port (5173) — this is what makes the
  comparison meaningful; a screenshot of only one side is weak evidence
- the page body does not scroll horizontally at the widths you check

On both ports, after the flow, check `browser_console_messages` (`level:
"warning"`, `all: true`) and `browser_network_requests` (`static: false`, no
`filter`) — same strict-catch discipline as `/browser-verify`: **do not**
filter by keyword or component name, and do not discard a warning, error, or
failed request as "unrelated" just because it doesn't look connected to this
issue. A regression from this change can surface in code the diff never
touched — a shared provider, a background poller, a context higher in the
tree. Report every new one, tagged with which port and which scenario
surfaced it, in step 6. Silence here should mean "checked, found nothing,"
never "didn't check."

Then walk the QA artifact's **Interaction cases from the blast radius** section
(or, on the fallback path, the plan's **Interaction surface** list), one item
at a time, on the changed port: this is exactly the set of neighbouring
features `/implement-issue`'s Phase B `scout` dispatch already flagged as worth
checking, not a smoke test of the whole app, and not a list to re-derive from
the diff yourself. Repeat the same console/network check after each
interaction case, not just the initial screen — a case further down the list
is exactly where an unrelated-looking regression tends to hide.

**If a scenario needs CRM data that isn't in the sandbox** (an Opportunity in
a particular stage, an Account with a particular field), don't skip the
scenario — seed it with the `sf` CLI per
`docs/runbooks/salesforce-sandbox-local.md`'s "Seeding QA/test data via the
Salesforce CLI" section. Query-then-create (reuse a fixture that's already
there), name it `ZZ-TEST ENG-<id> - <slug>`, and force a sync so it actually
reaches the app before you go looking for it in the UI. Note what you created
in your report (step 6) — step 7's hand-off reminds you to delete it.

### 5. Run the issue's e2e spec, if one exists

Check whether the root PR touched `tests/e2e/tests/**`. If it did:

```bash
cd "$AP_WORK_REPO/tests/e2e"
npx playwright test tests/cockpit/<spec>.spec.ts --project=chromium
```

`PLAYWRIGHT_BROWSERS_PATH` is already exported by `ap-env.sh` (step 2), so the
nix-built browsers resolve without extra setup.

**Known blocker, not yours to debug:** the suite's login currently needs a seeded
password that does not exist yet (see the runbook's Step 3). If login fails with
this specific symptom, report it as the known blocker and move on — do not spend
the run trying to fix authentication.

If no e2e spec exists for this issue, say so and skip this step; it is not a gap in
your testing, the issue simply has none.

### 6. Report a verdict

Short and evidence-led:

Report step 1b's four checks as **four separate lines**, not one bucket — collapsing
them lets a clean result on one stand in for the others, which is exactly the
failure mode splitting them exists to prevent. If any of the four found nothing to
flag, say so plainly rather than omitting the line — silence here should mean
"checked, clean," never "skipped":

- **Root-cause coverage** — which artifact-named fix sites are covered in the diff,
  and which are absent with a documented descope, quoted. This answers only "did the
  PR do what the RCA asked" — it says nothing about whether the RCA asked enough.
- **Surface coverage** — what the independent re-scan (not the artifact's own list)
  found: any location the root cause's pattern reaches that the artifact never named
  at all. **This is the finding that should most change a merge decision** — an
  undiscovered sibling sharing the same defect is not a nitpick, and a clean
  Root-cause coverage line does not make this one clean too. If the re-scan found
  nothing outside what the artifact already named, say that plainly.
- **Adversarial-review test backing** — which must-preserve cases (if the artifact
  has an Adversarial Review section) have a real matching test, and which have only
  the artifact's word for it.
- **Mutation spot-check** — the one claimed mutation you personally reproduced:
  fail-then-pass, or "not attempted" and why.
- **Verified here**, with the evidence — the diff, the screenshot pair, the passing
  spec output. Includes the spot-checked items from the artifact's own
  **Verified here** section (say which ones you spot-checked, not that you
  re-ran all of them).
- **Needs a human** — the artifact's own **Needs a human** section, executed:
  for each item, either resolve it now with evidence, or confirm it is still
  genuinely blocked and why (the seeded-password blocker, a missing
  credential). Anything only a person can judge (does the screenshot actually
  look right, is the copy correct, is the UX acceptable) belongs here too.
- **Contradicts the artifact** — anything the QA artifact's sections (or, on
  the fallback path, the plan's Verification or Interaction surface section)
  claimed that you found to be false. Lead with this, or with a Root-cause
  coverage or Surface coverage gap, whichever exists — those are the most
  important things you will report, ahead of everything else in this list.
- **Unexpected findings** — any console warning/error or failed network
  request the browser walk surfaced that the QA artifact didn't call out,
  even if it doesn't look related to this issue. List it here rather than
  folding it into "Contradicts the artifact" (that's about a claim being
  false — this is new information) or dropping it because you couldn't
  immediately explain it.

### 7. Hand off

Print the exact command for the human to run next:

```
/ship-work <plan path>
```

That confirms the PR(s) are rebased onto the latest `dev` and locally
gate-clean — it does not wait on CI or merge. Once CI is green on GitHub, the
human merges it themselves (GitHub UI or `gh pr merge`).

If step 1 found drift against `dev`/`main` or a conflict in the merge-tree probe,
say so again here and point at `/ship-work` to resolve it (it rebases properly)
— never propose a manual rebase from this skill.

If step 1b found an undocumented gap — a Root-cause coverage gap (an artifact-named
fix site the diff never touched, with no descope note) or a Surface coverage gap
(an independently-found location sharing the same root cause that the artifact
never named and nothing addresses) — **say so here too, explicitly, before printing
the `/ship-work` line**, and name it as a reason to hold rather than merge. A
documented, deliberate descope (a quoted "Decision" section, a named follow-up
ticket) is not this — that is normal scoping and does not block the hand-off.

And remind them explicitly: **after the merge, close the ticket**
(`ap_queue.py set <ENG-ID> --state done --event "merged"`). The pipeline
does not close it, and it keeps showing up in the daily brief until someone
does.

**If step 4 seeded anything in the Salesforce sandbox, delete it now** — the
same query-then-delete from the runbook's seeding section, scoped to that
`ZZ-TEST ENG-<id>` prefix, children before parents. A record left behind is
pollution in a sandbox other engineers also use; don't leave that for a
later run to notice.
