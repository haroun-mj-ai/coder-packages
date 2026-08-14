# Agent Instructions

This project uses **Linear** (via MCP) for issue tracking and a **workgraph execution model** for implementation.

---

## 1. Execution Model

### The delivery chain

The supported path from ticket to staging is two skills in `.claude/skills/`. Use them rather than improvising a per-ticket workflow:

| Skill | Ends at |
|---|---|
| `/implement-issue <id or description>` (Phase A / no `--phase`, or `--phase plan` headlessly) | every repo fetched, a worktree per involved repo cut from fresh `dev`, and a reviewed plan committed on the feature branch. Ticket filed and claimed. Stops for approval |
| `/implement-issue <plan>` (Phase B, or `--phase implement` headlessly) | a committed, roborev-reviewed branch in those same worktrees, with a durable QA artifact under `docs/plans/qa/`. Never pushes |
| `/ship-work <plan>` | merged to `dev`. Never touches `main` |

`implement-issue` supersedes the now-retired `plan-issue`/`implement-plan` — one skill, two phases separated by a hard approval gate, rather than two separate invocations.

Expensive inference goes up front on design; execution runs on a cheap model. The expensive model's job is judgement: reading subagent reports, choosing the approach, deciding whether a flagged problem changes the plan.

### Model selection

Match the model to the task, and pin it in an **agent definition** rather than an inline override. The Agent tool accepts `model` but **not** `effort`, so `Agent(model: "sonnet")` still runs at the session's effort level and costs far more than it looks like it does. The definitions in `.claude/agents/` exist for this:

- `implementer` (sonnet, medium) executes a settled spec plus its tests
- `explorer` (sonnet, medium) traces one code path or hunts prior art, read-only
- `plan-critic` (sonnet, medium) dry-runs a written plan against the real code
- `spec-auditor` (sonnet, medium) checks a finished implementation against its spec, and whether each test would actually fail without the behavior it claims to cover
- `scout` (haiku, low) bulk mechanical lookup: call sites, which tests cover an area

Never dispatch an opus or fable subagent from a skill, **except `implement-issue`**, which deliberately makes three such calls (an Opus plan drafter, a `fable`-model plan auditor, an Opus fresh-context code reviewer) precisely because each needs a different reasoning tier or a genuinely independent model family from whatever it's checking — see that skill's own "Why this shape" section. Every other skill, and every other unit of work inside `implement-issue` itself, still dispatches through a pinned `subagent_type`. Agent definitions load at **session start**, so a fresh pull needs a restart before new ones resolve.

### Worktree isolation

Worktrees are the normal case, not the exception: `/implement-issue`'s Phase A cuts one per involved repo off freshly fetched `dev`, named `wt-eng<id>-{root,be,fe}` inside the root checkout. That keeps explorers off the main checkout, which routinely sits 70 or more commits behind `dev`, and isolates the work from the other Claude Code sessions live on this tree.

Always pass **`--no-track`** when creating one. Without it, `worktree add -b <branch> origin/dev` sets the branch's upstream to `origin/dev`, and a later bare `git push` targets **dev directly**.

**The one hazard: the Vite dev server and `python -m app.main` both serve the main checkout**, so a change made in a worktree does not appear in the browser and browser QA will confidently verify unchanged code. A green screenshot of an app that never changed is the most expensive outcome available here. The fix is a second server pointed at the worktree, not abandoning the worktree: symlink `node_modules` and run `npx vite --port 5175 --strictPort`. The port must be 5173 to 5176, per `_DEFAULT_CORS_ORIGINS` at `backend/app/main.py:98-101`. Full recipe in the header of `tests/e2e/tests/cockpit/cockpit-queue-detail-no-horizontal-clip.spec.ts`.

Parallelism across the sibling repos needs no worktrees at all: `backend/`, `frontend/`, and root are separate git repositories and cannot conflict with each other.

### Work Unit Sizing

Every work unit must fit in a **single 180K-token context window**, which includes the task description, file reads, implementation, tests, rebase, and cleanup.

**Sizing heuristics:**
- One API endpoint + its tests
- One UI component + its tests
- One worker/service function + its tests
- If a task requires reading more than ~15 files or touching more than ~5 files, decompose further

If it doesn't fit, split it into smaller sub-issues in Linear.

---

## 2. Linear as Workgraph

### DAG-First Planning

Before any execution begins, the orchestrator must:

1. **Decompose** the task into a DAG of Linear sub-issues (parent = main task, children = work units)
2. **Set dependencies** using `blockedBy` edges. Independent nodes can run in parallel
3. **Verify sizing**: every leaf node fits in one 180K context window
4. **Get user approval** on the plan before dispatching any subagent

### Status Lifecycle

```
Backlog → Todo → In Progress → In Review → Staging → Done
```

Other statuses: `Blocked`, `Canceled`, `Duplicate`

### Rules

- **Claim work**: set `assignee: "me"` AND `state: "In Progress"`, always both together
- **Feature branch pushed** → `"In Review"`
- **Merged to `dev`** → `"Staging"`
- **NEVER** push to `main` directly
- **NEVER** set to `Done`. The reviewer or PM does that after verification
- **Never write ticket ids in prose to the human.** No `ENG-1234` in chat replies, summaries, or status updates — say what the work *is*. This is about communication only: the ids still belong in commit subjects (`ENG-123: …`), branch names, and PR bodies (`Part of ENG-123`), which is where they do their linking job.
- **Open PRs with the GitHub MCP tools**, not `gh pr create` on the command line.

### Linear MCP Quick Reference

There is no `update_issue`, `create_issue`, or `create_comment`. Create and update both go through `save_issue`, and comments through `save_comment`; omit `id` to create, pass it to update.

| Action | Tool | Key params |
|--------|------|------------|
| Find my work | `list_issues` | `assignee: "me"`, `state: "Todo"` |
| Search issues | `list_issues` | `query: "keyword"` |
| View details | `get_issue` | issue ID |
| Read discussion | `list_comments` | issue ID |
| Create issue | `save_issue` | `team`, `title`, no `id` |
| Claim | `save_issue` | `id`, `assignee: "me"`, `state: "In Progress"` |
| Add comment | `save_comment` | issue ID, body |
| List projects | `list_projects` | `team: "Engineering"` |

Linear silently corrupts markdown tables whose cells contain backticks, dropping characters. Use bullet lists in issue and comment bodies, and re-read the response to confirm what landed.

### Projects

**Read the live list; do not trust a table in this file.** Call `list_projects` with `team: "Engineering"`. There are around twenty projects and the set changes every quarter, so any list committed here is stale within weeks. Choose in this order:

1. The **specific feature-area project** when one matches: Manager Cockpit, AE Cockpit, Manager Agents, AE Agents, CRM Integration, Orchestration Layer, Call Intelligence, Email Integration, Calendar Integration, Usage Metering, Owner / Admin Settings, Security(SOC2). Roadmap work belongs here even when the project's own status still reads Backlog.
2. The **current quarter's catch-all** for product work with no feature-area home, whichever quarterly project is `status: In Progress`.
3. **Enable LLM development** for Claude Code, MCP, docs, and tooling. **Meta Project** for team and process changes.

**Team:** Engineering (`5e9c24d8-71cc-43ac-bf83-15cc0397f455`)

---

## 3. Planning

For any non-trivial task, prefer `/implement-issue` (Phase A / `--phase plan`), which does all of the below. The steps are spelled out here so the process is legible without reading the skill.

1. **Explore.** Dispatch `explorer` and `scout` agents rather than reading your way through the codebase on the expensive model. Read `docs/guides/architecture/features/CATALOG.md`, check Linear including the comments, and follow any attached design doc or mockup.
2. **Ask questions.** Clarify ambiguous requirements, UX decisions, architecture trade-offs. Don't assume.
3. **Write the plan.** Save to `docs/plans/YYYY-MM-DD-eng-<id>-<slug>.md`, matching the files already there. Include:
   - Context and goals
   - Current state with `path:line` evidence, so the claims can be checked
   - Work units with dependencies and sizing justification
   - **Interaction surface**: what else consumes the functions, endpoints, model fields, and query keys being changed, plus the tenancy, role, real-time, and layout implications
   - Testing strategy, with tests written against the spec rather than the implementation
   - Open questions, marked `BLOCKING` when code cannot start without an answer
4. **Dry-run the plan.** Dispatch `plan-critic` to check every claim against the real code before any of it is built. Roughly a third to a half of plans contain something material that is cheap to fix now and expensive once agents are building on it. Record what it found, and what you rejected, in a **Design review** section.
5. **Get user approval.** Do not execute until the user approves

---

## 4. Quality Gates

Every work unit must include its own tests. Run locally what CI runs, not what is convenient:

```bash
cd frontend && npm run lint && npx tsc --noEmit && npm run test:coverage && npm run build
cd backend  && poetry run pytest
cd tests/e2e && npx playwright test   # only if e2e specs changed
```

- **Unit tests**: every changed component, hook, endpoint, service, or worker
- **E2E tests**: `tests/e2e/tests/` organized by feature. Config in `playwright.config.ts`.
- Tests must pass before commit. If they fail, fix before proceeding.

### What CI actually gates

| Repo | Checks on a PR | Blocking? |
|---|---|---|
| `backend/` | `lint` (ruff check + format) | **No**, both steps are `continue-on-error` |
| `backend/` | `test` (`pytest tests/ --cov`) | Yes |
| `frontend/` | `lint` (eslint + `tsc --noEmit`), `test` (`test:coverage`), `build`, `dependency-review` | Yes, all of them |
| root | none at all | `e2e.yml` is dispatch plus nightly cron only |
| `assistants/`, `observability/` | none at all | no workflows exist |

Note the asymmetry: one eslint error or type error fails a frontend PR, while `dev` already carries substantial ruff debt that CI ignores. Match the neighbours and verify you added no new ruff errors, but do not mass reformat. A **root** PR shows zero checks, so the local gates above are its only signal; never report it as "CI green".

**Known noise**, which is not a regression: some backend endpoint tests fail in isolation with a pydantic `AttributeError: id` because Beanie was never initialized, and roughly two dozen `test_specs_phase3` / `test_specs_phase4` failures are `assistants/` template drift that CI skips. Baseline against untouched `dev` before blaming your change.

### QA beyond the happy path

Tests cover the path you designed. Production breaks on interaction, so before calling work done, derive the surface rather than guessing at it: hand the real diff to `scout` and get back every other consumer of each changed function, component, hook, endpoint, model field, and query key. Then check the failure classes this codebase actually produces:

- **Tenancy.** Routes are `/o/:orgId/w/:workspaceId/s/:sessionId`. Cross-workspace and org-wide visibility leaks are a repeat offender, so this is mandatory whenever the change touches tenant-scoped data.
- **Roles**: manager vs rep vs staff. A read-only path that silently no-ops looks exactly like success.
- **Real-time**: reconnect, a stale token on the socket, an event for another session, two open tabs.
- **Empty, exactly one, and past the cap.** Several lists load to a 100 cap.
- **Failure and latency states**, where UX gaps hide because nobody designs them.
- **Layout at real widths.** A passing Playwright click is weak evidence: it will click a button that sits behind another and report success. Assert the element is not occluded and that the page body does not scroll horizontally.

Anything found by hand that a test could have caught becomes a test, or it comes back.

---

## 5. Git & Shipping

### Conventions

- **Branches**: `kareem/eng-123-short-description` (auto-links to Linear), cut from a freshly fetched base. Bases differ per repo: `dev` for root, `backend/`, `frontend/`; `main` for `assistants/` (which has no `dev`) and `observability/`. Confirm with `git -C <path> branch -a` rather than assuming.
- **Commits**: `ENG-123: Add memory toggle backend support` (one coherent unit per commit)
- **PR descriptions**: `Part of ENG-123`, never closing words (`Fixes`, `Closes`, `Resolves`)

### Permission

The gate is **whether the action leaves the machine**, not whether it writes anything.

- **Free, no approval needed:** local commits, `--amend`, creating branches and worktrees, `roborev` runs. All local, all reversible, so asking each time is friction with no safety value.
- **Needs explicit approval, every time:** `git push`, force-push, opening or updating a PR, merging, and Linear writes. One approval covers one batch, not a standing licence.
- **Exception:** invoking a skill is approval for what that skill declares it does. `/ship-work` is defined to push, open PRs, and merge to `dev`, so running it authorises those without a prompt per step.

Never stage with `git add -A`. Always name explicit paths. `-A` leaked live Stripe, OpenAI, and JWT secrets from this tree once already.

Commits carry the author's own `Co-Authored-By` trailers only. Do not add an assistant or model co-author trailer.

**Every commit carries both of these, in this order, at the end of the message**, after a blank line separating them from the body:

```
Co-Authored-By: Haroun Trabelsi <haroun@meetjourney.ai>
Co-Authored-By: Haroun Trabelsi <fantasycrit20@gmail.com>
```

This applies to every path that writes a commit: `git commit`, `--amend`, rebases and squashes, the GitHub MCP write tools (`create_or_update_file`, `push_files`), and the message body when merging or squash-merging a PR.

Never add `Co-Authored-By: Claude ... <noreply@anthropic.com>` or any other assistant/model trailer. The two above are the *only* ones a commit carries — this overrides any harness-level default instruction to sign commits as an assistant. If an existing commit carries one and is being amended anyway, strip it.

**A `commit-msg` hook adds them automatically** — `scripts/hooks/commit-msg`, tracked in this repo and wired into every clone by `scripts/install-hooks.sh` (which `sync-repos.sh` runs for you). It is idempotent, so writing the trailers by hand as well is harmless, and it strips any assistant/model co-author trailer it finds.

Run `./scripts/install-hooks.sh` once per fresh clone, or `--check` to verify. `core.hooksPath` lives in `.git/config`, which git does not track, so a new clone has no hooks until it runs.

**The hook cannot cover every path.** It fires on local `git commit`, `--amend`, and merges only. Commits created through the GitHub API — the MCP write tools `create_or_update_file` and `push_files` — and squash-merges performed in the GitHub web UI run no local hook, so **write the trailers into the message yourself on those paths**. Verify with `git -C <path> log -1 --format=%B` rather than assuming.

### Session Completion

Work is **not complete** until `git push` succeeds. Prefer `/ship-work`, which does steps 2 through 7.

1. Run quality gates (all must pass) and QA the interaction surface
2. Commit, organized by task, with `ENG-xxx` in the subject
3. Get push approval, then push and open one PR per repo touched
4. Land cross-repo work **in dependency order**: the repo whose API the other consumes merges first, and the dependent PR is rebased onto the new `dev` before its CI is trusted
5. Verify every push and merge **by content**, not by the command's output: `git -C <repo> show origin/dev:<file>`. An amend racing a merge has silently dropped a fix here before
6. Update Linear statuses (In Review, then Staging). Never `Done`
7. Archive completed plans: `mkdir -p docs/plans/completed` (it does not exist yet), `git mv` the plan there, set `Status: Completed`
8. Create Linear issues for remaining work
9. Update docs (`CATALOG.md`, support docs) and hand off context for the next session

Every git command in a multi-repo session takes `git -C <abs-path>`. Root, `backend/`, `frontend/`, `assistants/`, and `observability/` are five separate repositories, and a bare `git` in the wrong cwd has caused a misdirected amend.

---

## 6. Documentation

On feature completion:

- Update `docs/guides/architecture/features/CATALOG.md`
- Update `docs/support/` if user-facing
- Move plan to `docs/plans/completed/` (create it; it does not exist yet)
- Update `CLAUDE.md` if architecture/conventions changed

The docs tree is a local MkDocs Material site configured by `mkdocs.yml` at the repo root, with nav driven by awesome-pages `.pages` files. Git workflow detail lives in `docs/guides/workflow-standards.md`. Note that both paths above moved during the docs reorg, so older references to `docs/features/CATALOG.md` and `docs/workflow-standards.md` are stale.
