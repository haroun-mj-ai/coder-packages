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
/test-issue next     # oldest inbox issue labelled ready-to-test
/test-issue          # same as next
```

## Instructions

### 1. Read the QA artifact first — do not re-derive what it already computed

If given `next` or no argument, list the inbox (`$AP_INBOX_REPO`, from `ap-env.sh`)
for open issues labelled `ready-to-test` and take the oldest by creation date.

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
either the inbox issue's `Plan file: <abs path>` line, or the newest matching
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

Then walk the QA artifact's **Interaction cases from the blast radius** section
(or, on the fallback path, the plan's **Interaction surface** list), one item
at a time, on the changed port: this is exactly the set of neighbouring
features `/implement-issue`'s Phase B `scout` dispatch already flagged as worth
checking, not a smoke test of the whole app, and not a list to re-derive from
the diff yourself.

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
  claimed that you found to be false. Lead with this if it exists; it is the
  most important thing you will report.

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

And remind them explicitly: **after the merge, close the inbox issue.** The
pipeline does not close it, and it keeps showing up in the daily brief until
someone does.

**If step 4 seeded anything in the Salesforce sandbox, delete it now** — the
same query-then-delete from the runbook's seeding section, scoped to that
`ZZ-TEST ENG-<id>` prefix, children before parents. A record left behind is
pollution in a sandbox other engineers also use; don't leave that for a
later run to notice.
