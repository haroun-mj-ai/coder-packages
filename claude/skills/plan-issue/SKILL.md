---
name: plan-issue
description: Turn a Linear issue into a reviewed implementation plan, fetching every repo and exploring inside worktrees cut from fresh dev so the evidence is not stale, using cheap Sonnet and Haiku subagents for all the code reading and a dry-run design review before any code is written. Given a free-text description instead of an issue id, it files the Linear issue first. Use when starting work on a ticket, when asked to plan or spec a feature or bug fix, or on /plan-issue. Pairs with /implement-plan, which builds the approved plan. Do NOT use to write feature code.
---

# plan-issue

Produces a reviewed plan, committed on a feature branch inside a worktree cut from
fresh `dev`, and stops. Implementation is `/implement-plan`, a separate invocation
after the human has read the plan.

## Usage

```
/plan-issue ENG-123
/plan-issue https://linear.app/.../issue/ENG-123/...
/plan-issue the pipeline board loses column order after a CRM sync
/plan-issue ENG-123 --no-claim      # skip the Linear assignee/status write
/plan-issue <description> --no-issue  # plan without creating a ticket at all
```

Given an issue id or URL, the skill reads that issue. Given a free-text
description, **it creates the Linear issue first**, so that the ticket, the plan
file name, the branch, and the commit all share one id. Use `--no-issue` only for
work that genuinely should not have a ticket, such as a local tooling spike.

## Why this shape

Expensive inference belongs at the front, on design. Cheap inference does the
reading and later the building. Two rules follow from that and they are not
negotiable:

- **You (the main session) do the judging. Subagents do the reading.** Do not
  read your way through the codebase yourself, and do not ask a subagent what the
  design should be.
- **Cheap means a pinned agent definition, not an inline model override.** The
  Agent tool accepts `model` but *not* `effort`, so `Agent(model: "sonnet")`
  inherits this session's effort and costs far more than it looks like it does.
  Always dispatch by `subagent_type`: `explorer` and `plan-critic` (sonnet,
  medium) and `scout` (haiku, low). **Never** spawn an opus or fable subagent
  from this skill.

  These definitions live in `.claude/agents/` in this repo. Agent
  definitions are loaded at session start, so if a dispatch fails with "agent type
  not found" after a fresh pull, the session predates the file. Say so and ask
  for a restart rather than falling back to an inline model override, which would
  silently run at this session's effort level.

Budget discipline: at most 3 explorers, one exploration round, one critic. If the
task is small enough to hold in one head, say so and skip the fan-out rather than
performing it for appearances.

## Instructions

### 0. Fetch every repo, and report the drift

Do this before anything else. The main checkout sits on whatever feature branch was
last worked, and it is routinely **70 or more commits behind `origin/dev`**. An
explorer reading that tree returns `path:line` evidence that is wrong by tens of
lines, and reports things as absent that landed on `dev` last week. A plan built on
that is worse than no plan, because its claims look checkable.

```bash
for r in . backend frontend assistants observability; do
  git -C "$r" fetch origin --quiet
done
for r in . backend frontend; do
  printf "%-10s " "$r"
  git -C "$r" rev-list --left-right --count origin/dev...HEAD
done
```

Report the drift. It is the number that justifies step 2b, and if it is zero for
every repo you can say so and skip the worktrees.

### 1. Ground truth first, before reading any code

#### 1a. Given an issue id or URL

- `mcp__linear-server__get_issue` for the description, and
  `mcp__linear-server__list_comments` for the discussion. Requirements are very
  often only in the comments.
- Follow what it points at. Design docs and mockups get attached rather than
  written inline: `WebFetch` a Netlify or docs link, `Read` a screenshot, read a
  referenced PDF with the `pages` parameter.
- If the issue is thin, say so explicitly in the plan's open questions rather
  than inventing the requirement.

#### 1b. Given a free-text description: create the issue

Do this before any exploration, so the id is available for the plan file name and
so a mis-scoped ticket gets killed cheaply rather than after three explorers have
run.

**Check for an existing ticket first.** `mcp__linear-server__list_issues` with
`query: "<the distinctive keywords>"`. Someone has often already filed it, and
Ryan files a lot. If a plausible match exists, show it and ask whether to plan
that one instead of creating a duplicate. Also scan `docs/plans/` for the same
symptom.

**Do not create a vague ticket.** If the description is too thin to write a title
and a one-paragraph problem statement without inventing the requirement, ask the
one question that resolves it. A ticket nobody else can read is worse than no
ticket, because it looks like work is tracked when it is not.

Otherwise create it with `mcp__linear-server__save_issue` (omit `id` when
creating):

- `team: "Engineering"` (id `5e9c24d8-71cc-43ac-bf83-15cc0397f455` if the name
  does not resolve)
- `title`: short and imperative, the change not the symptom. "Preserve pipeline
  column order across a CRM sync", not "pipeline is broken".
- `description`: the user's own words for the problem, kept intact, plus the
  observed behavior and the expected behavior if they said them. State what is
  wanted, not how it will be built; the how goes in the plan comment at step 7.
  Mark anything you inferred rather than were told as an explicit assumption line,
  so the requester can correct it.
- `project`: **read the live list, do not use a hardcoded one.** Call
  `mcp__linear-server__list_projects` with `team: "Engineering"` and
  `fields: ["id", "name", "status"]`. The four projects named in `AGENTS.md` §2
  are the Q1-era set and no longer reflect the workspace. Choose in this order:
  1. the **specific feature-area project** if one matches (Manager Cockpit, AE
     Cockpit, Manager Agents, AE Agents, CRM Integration, Orchestration Layer,
     Call Intelligence, Email Integration, Calendar Integration, Usage Metering,
     Owner / Admin Settings, Security(SOC2)). These are where roadmap work
     belongs, even when their own status still reads Backlog.
  2. the **current quarter's catch-all** for product work with no feature-area
     home, whichever quarterly project is `status: In Progress`.
  3. **Enable LLM development** for Claude Code, MCP, docs, and tooling; **Meta
     Project** for team and process changes.

  State which you chose and why in one line. Ask only when it is genuinely a coin
  flip.
- `assignee: "me"` and `state: "Todo"`. Step 7 flips it to In Progress once the
  plan exists, which keeps the status honest about what has actually happened.
- `labels` only when the description clearly says bug or feature. Never guess a
  label, and leave `priority` unset: that is the requester's call, not yours.

Then **report the created id and URL immediately**, before spending anything on
exploration. Everything downstream uses that id.

If the Linear MCP is unavailable, say so and continue with `--no-issue` behavior
rather than silently planning against a ticket that does not exist.

Then check what already exists, so you extend rather than duplicate:

```bash
ls docs/plans/ 2>/dev/null | grep -i <keyword>
ls docs/plans/completed/ 2>/dev/null | grep -i <keyword>   # dir may not exist yet
```

and skim `docs/guides/architecture/features/CATALOG.md` for the feature area (the
docs reorg moved it; `docs/features/` no longer exists).

### 2. Orient cheaply with one scout

Before deciding what to explore, dispatch a single `scout` (haiku) to answer the
mechanical question: **which of the repos are in play, and where does this area
live?** The four repos are separate git checkouts as siblings:
`/home/coder/root-for-local` (root: docs, tests/e2e, scripts),
`backend/`, `frontend/`, `assistants/`. Only root is tracked by this repo's git;
the others are gitignored siblings with their own history.

Confirm branch state yourself, per repo, using absolute paths:

```bash
for r in . backend frontend assistants; do git -C "$r" status -sb | head -2; done
```

A bare `git` command in the wrong cwd reports the wrong repository. This has
already caused a misdirected amend.

**State the scout's limit in its prompt.** It is reading the stale main checkout, so
its output is for **locating** things (which repo, which area) and never for line
numbers. Nothing downstream may quote a scout line number as evidence; that comes
from the explorers in step 3, which read fresh worktrees.

### 2b. One worktree per involved repo, cut from fresh `dev`

Now that the ticket id exists and the scout has named the repos, give the explorers
a clean tree to read. Always the root repo, since it will hold the plan doc, plus one
per repo the scout named. Skip entirely if step 0 showed zero drift everywhere.

**Reuse before creating.** Another session may already have one, and this convention
is in live use across sessions:

```bash
git -C <repo> worktree list | grep "wt-eng<id>-"
```

If a matching worktree exists, use it and say so. Otherwise:

```bash
git -C <repo> worktree add --no-track \
  /home/coder/root-for-local/wt-eng<id>-<suffix> \
  -b haroun/eng-<id>-<slug> origin/dev
```

- **`--no-track` is not optional.** Without it git sets the new branch's upstream to
  `origin/dev`, and a later bare `git push` from that worktree targets **dev
  directly**. With it, a bare push fails safely and `/ship-work` sets the real
  upstream with `push -u`.
- Suffix matches the convention already in the tree: `-root`, `-be`, `-fe`
  (see `wt-eng1098-root`, `wt-eng1003-files-be`, `wt-eng1003-files-fe`).
- Base per repo: `dev` for root, `backend/`, `frontend/`; `main` for `assistants/`
  and `observability/`. Confirm with `git -C <path> branch -a`, never assume.
- If the branch already exists, drop `-b` and add the worktree on it. If it is
  checked out in another worktree, git refuses with a clear `fatal:`. Use that
  worktree; never force.
- Verify freshness rather than trusting it:
  `git -C <worktree> rev-list --count HEAD..origin/dev` must be `0`.
- Report every path created or reused before exploring.

Note that a root worktree contains **no `backend/` or `frontend/`**: those are
gitignored siblings with their own history, which is exactly why each repo needs its
own worktree rather than one for root.

### 3. Fan out 2 to 3 explorers, in a single message

One message with multiple `Agent` calls so they run concurrently. Give each a
disjoint question. The usual split:

- **Current state**: trace the code path that owns the behavior today, end to
  end.
- **Prior art**: how does this codebase already solve the adjacent problem?
  Which utilities, hooks, components, or services should be reused rather than
  rewritten?
- **Verification surface**: which tests cover this area, where do they live, how
  are they run, and what is the established pattern for testing this kind of
  change?

Every explorer prompt must carry:

- the **absolute worktree path** from step 2b, never the main checkout. This is the
  payoff of the whole setup: the explorer reads canonical fresh `dev` and cannot be
  disturbed by one of the other live sessions editing the main tree mid-run. Say in
  the prompt that the path is a worktree of fresh `dev`, so its `path:line` output is
  quotable as evidence,
- a note that other repos are covered by its peers,
- the specific question, narrowly framed,
- the ticket's own words for what is wanted, so it can spot the mismatch,
- an instruction to report `path:line` evidence with short quotes, **not** whole
  files,
- an explicit demand for the **"what does not exist"** section. The hook that
  isn't there is what saves the plan.

Cap at 3. Do not run a second round unless the first came back genuinely empty
on a question the plan cannot be written without, and say why when you do.

### 4. Write the plan

Synthesize yourself. This is the step the expensive model is for: reconciling
what the explorers found with what the ticket wants, choosing the approach,
naming the edge cases, and deciding what is out of scope.

Write it **inside the root worktree**, at
`<root-worktree>/docs/plans/YYYY-MM-DD-eng-<id>-<slug>.md` (or
`YYYY-MM-DD-<slug>.md` under `--no-issue`), following `plan-template.md` next to
this file. Then commit it there on the feature branch:

```bash
git -C <root-worktree> add docs/plans/<plan>.md
git -C <root-worktree> commit -m "ENG-<id>: plan"
```

Committing is free and needs no approval, and this is the reason the root worktree
exists. A plan written into the main checkout sits untracked on whatever branch that
tree happens to be on, which is how `docs/plans/` accumulated eight untracked plans.
Committed on the feature branch, it travels with the work and `/ship-work` has a real
file to archive.

If step 0 showed zero drift and no worktree was created, write it in the main
checkout as before, and say that the plan is untracked.

Non-negotiable parts:

- **Evidence.** Every claim about current behavior carries a `path:line`. A plan
  whose claims cannot be checked cannot be dry-run reviewed.
- **Work units.** Each sized to a single context window per `AGENTS.md` §1:
  roughly, if it needs reading more than ~15 files or touching more than ~5,
  split it. Each unit names its repo, its files, and its own tests. These become
  the dispatch list for `/implement-plan`, so they must be independently
  executable by an agent that has not seen this conversation.
- **Tests against the spec, not against the implementation.** For each behavior
  the plan describes, name the test that will fail before the change and pass
  after. The spec, the tests, and the code are three independent points of truth;
  tests that merely restate the implementation collapse that to two.
- **The interaction surface.** What else consumes the functions, components, hooks,
  endpoints, model fields, and query keys being changed, with `path:line`. Plus the
  tenancy, role, real-time, and layout questions in the template. This is the
  section that stops a plan from being correct in isolation and wrong in the app.
  One of your explorers should have been pointed at exactly this.
- **Open questions**, and mark any that must be answered before code can be
  written as `BLOCKING`. `/implement-plan` refuses to run while one is open.
- **No `ENG-###` in the code or comments** the plan proposes. Ticket ids belong
  in the branch name, the commit subject, and the plan's own header.

### 5. Dry-run the plan against reality

Dispatch **one** `plan-critic` with the plan file path and the ticket's
requirement. It labels each claim VERIFIED / WRONG / MISSING and lists the gaps.

This step exists because roughly a third to half of plans contain something
material that is cheap to fix now and expensive to fix once three agents are
already building on it.

### 6. Reconcile, and record what you did

Judge the findings yourself; do not apply them mechanically. Fix the wrong claims,
absorb the real gaps, resize any unit it flagged as too large. Then add a
**Design review** section to the plan recording what the critic raised, what you
changed, and what you rejected with the reason.

Keep that section honest even when the critic found nothing. It is the only
evidence over time of whether this step earns its cost. If the verdict was
`DO NOT IMPLEMENT`, do not paper over it: rework the approach and re-run the
critic once, or surface it to the human as a blocking question.

### 7. Linear

There is always an issue id by now unless `--no-issue` was passed, since step 1b
creates one. Skip this whole step under `--no-issue`, and skip only the second
bullet under `--no-claim`.

- `mcp__linear-server__save_comment` with a summary and the plan path: one
  comment, not a running commentary. Use **bullet lists**; Linear corrupts
  markdown tables whose cells contain backticks, silently dropping characters.
  Re-read the response to confirm what landed.
- `mcp__linear-server__save_issue` with `assignee: me` and `state: In Progress`,
  per `AGENTS.md` §2. Set both together. Never set `Done`.
- If the plan raised a **BLOCKING** question that only the requester can answer,
  put it in that same comment addressed to them by `@displayName`, rather than
  only surfacing it in chat. They answer in Linear anyway, and this stops you
  being the relay while the work sits idle.

### 8. Hand back and stop

Report to the human:

- the decision you made and why, in a handful of lines, high level first;
- the **full plan path including the worktree**, since it is not in the main
  checkout and looking for it there is the obvious wrong guess;
- every worktree path and branch created or reused, and that `/implement-plan` will
  **reuse** them rather than cut a second set;
- the work unit list with their repos, so the shape of the build is visible
  without opening the file;
- anything `BLOCKING`, stated as a direct question;
- the next command: `/implement-plan <worktree>/docs/plans/<file>.md`.

**Stop there.** Do not begin implementing and do not touch feature code. Creating
the worktree and committing the plan into it is the whole of this skill's write
scope. The human reviews the plan first, and that review is the point of splitting
these two skills apart.

### 9. If the plan is rejected, clean up after yourself

When the human rejects the plan or abandons the ticket, remove what this run created
and nothing else:

```bash
git -C <repo> worktree remove <path>
git -C <repo> branch -d haroun/eng-<id>-<slug>
```

- **Only worktrees this run created.** One you reused belongs to another session.
- `worktree remove` refuses a tree with modified or untracked files. That is a
  feature: **never pass `--force`.** If it refuses, report why and leave it, because
  the unexpected content is more interesting than the cleanup.
- `branch -d` (lowercase) refuses to drop unmerged work. Do not reach for `-D`.

This tree already carries more than twenty worktrees, many stale. Planning a ticket
that never gets built should not add to that.

## Headless mode (`--headless`)

Shared mechanics — the `status.json` shape, the inbox contract, the
ask→fallback rule, the Linear footprint — are defined once in
`.claude/skills/autopilot-protocol.md`. Read it first. This section only maps
this skill's own ask points onto that protocol.

**Input is always an existing issue id**, extracted by `autopilot-poll` from
the title of the inbox issue the owner created to delegate the work — never
free text: `/plan-issue <description> --headless` with no issue id is
`FAILED`, `detail: "headless requires an issue id"`. Step 1b's create-a-ticket
path is interactive-only; its own asks (duplicate-ticket confirmation, thin
description) have no headless-safe default.

This skill's `NEEDS_HUMAN` inbox comments start with the line `Phase: plan`,
per the protocol's ask→fallback rule.

**Ask-point mapping** (step 1a/1b, only reachable given an issue id):

- **Duplicate-ticket match** (step 1b's existing-ticket check, reached only if
  a companion free-text flow surfaces one against the given id): plan the
  existing matching issue instead of the one passed in, and record that
  choice as an inbox comment. Do not ask.
- **Description too thin to write a title and problem statement** (step 1a):
  `NEEDS_HUMAN` — post the specific question that resolves it to the inbox
  issue, per the protocol's ask→fallback rule.
- **Project-selection coin flip** (step 1b's numbered priority order): take
  the **first matching rule** in that order and record the assumption — in
  the plan's own text and as an inbox comment — instead of asking. The
  priority order itself is the documented default the protocol requires.
- **"agent type not found" dispatch failure** (Why this shape, subagent
  dispatch): `FAILED` with that detail; there is no unattended remedy for a
  session that predates the agent definitions.

**`--feedback '<text>'`:** treat the text as new requirements from the
requester, not a correction to apply mechanically. Revise the existing
committed plan in place — same plan file, same branch, a new commit, not a
new file. Post the revised plan markdown to the inbox as a comment, the same
way a fresh plan is posted.

**End state:** commit the plan exactly as step 4 already does in interactive
mode. Then create or update the inbox issue with the **full** plan markdown
(body on create, comment on update), prefixed with the line `Plan file:
<absolute path>` per the protocol's inbox contract, label it `plan-review`,
and write `status.json` with `status: DONE`, `phase: "plan"`, and `plan_path`
set. Stop
there — do not begin `/implement-plan`. Step 7's Linear plan-summary comment
is interactive-only and is skipped headlessly; the Linear claim (`assignee:
me`, `state: In Progress`) still happens, per the protocol's Linear
footprint.

**Blocking open question in the plan itself** (step 4's `BLOCKING` marker,
survives the dry-run in step 5-6): still post the plan to the inbox, but
label it `needs-input` instead of `plan-review`, and write `status.json` with
`status: NEEDS_HUMAN` and `question` set to the blocking question's text.
