# Autopilot: 24/7 autonomous plan → implement → PR pipeline on the Coder workspace

- **Ticket:** none (`--no-issue` — personal/dev-infra tooling spike)
- **Status:** Draft
- **Repos touched:** root (skills), `coder-packages` (runtime scripts, installer), machine state (`~/.autopilot`, tmux, supercronic), Linear (2 labels), GitHub (new private inbox repo)
- **Date:** 2026-08-11

## Context

Haroun wants zero downtime on Linear issue delivery, day and night: whenever he
is not driving the terminal himself, Claude should be planning queued issues and
implementing approved plans on this Coder workspace, so that his own touchpoints
shrink to: label an issue, review the plan **privately from his phone**, test the
result against a running dev server, and run `/ship-work` to merge. The
three-skill chain (`/plan-issue` → `/implement-plan` → `/ship-work`) already
encodes the lifecycle; what is missing is (a) a scheduler that survives his PC
being off, (b) a headless mode for the skills, which today assume a human in the
terminal, (c) a **private** review/approval channel — Linear comments are visible
to the whole team, so plan content and approval must live elsewhere — plus phone
pings, and (d) rails so an unattended agent can push branches and open PRs but
never merge.

Decisions made with the user: runs 24/7, not just nights (budgets are per rolling
day); plan review is private, from the phone; substrate is cron + tmux running
headless `claude -p` (verified working with the cached Linear MCP OAuth);
notifications via ntfy.sh and/or Slack webhook; `/ship-work`'s merge step is
never run autonomously; serial processing; no resource-yielding needed — the only
non-interference requirements are that his VSCode/Coder access always works and
his own checkouts, branches, and baseline test servers are never touched.

## Current state

Verified on this machine (2026-08-11):

- Headless works: `claude -p` (v2.1.228) invoked non-interactively reached the
  Linear MCP with the cached OAuth token and returned a correct answer.
- **Skill drift (discovered during this planning pass):** the newest versions of
  the three skills live in `coder-packages/claude/skills/` (commit `bffcaff`,
  today) and are **ahead of** the copies tracked here on `dev` — e.g.
  implement-plan there is 559 lines and ends with a four-server handover section
  ("run them detached so they outlive the run", ports 5173-5176 / 8000-8001);
  the `dev` copy is 508 lines and ends at "Hand off to /ship-work" with no
  server section. All three SKILL.md files differ. Headless edits must build on
  the newer versions (U0), or they will resurrect stale behavior.
- The skills are interactive by construction. Every unresolved question is a
  synchronous chat "ask" that a `-p` run cannot answer:
  - plan-issue `SKILL.md:95-104` — duplicate-ticket and thin-description asks;
    `:118-133` sanctioned coin-flip project ask; `:350-353` "**Stop there.** …
    The human reviews the plan first".
  - implement-plan `SKILL.md:50-51` — "confirm the choice with the human before
    building"; `:54-59` hard stops on BLOCKING questions; `:67-68` stop-and-ask
    on uncommitted unrelated work; the newer (coder-packages) version ends by
    leaving **4 detached servers running** for a human to click — over repeated
    unattended runs this exhausts the 4-wide frontend port range (5173-5176).
  - ship-work `SKILL.md:24-46` — six hard stops that report to the terminal;
    `--no-merge` and `--dry-run` exist (`:17-19`); `merge_pull_request` only in
    step 8 (`:255-265`); the rebase step runs `git push --force-with-lease`
    (`:203`) and explicitly rejects `update_pull_request_branch` (`:195-198`).
- No skill writes machine-readable status: outcomes are prose in the final chat
  message. No `DONE`/`NEEDS_HUMAN`/`FAILED` vocabulary exists.
- Scheduler substrate absent: no `tmux`, no cron daemon, no systemd (PID 1 is
  `./coder agent`). Passwordless sudo (`NOPASSWD: ALL`); `tmux-3.7b` and
  `supercronic-0.2.48` resolve in the cached nixpkgs (`nix profile install`),
  and `supercronic` has a real `-test` crontab-validation flag.
- No user-controllable boot hook: the Coder `startup_script` is
  Terraform-side; nothing user-editable re-runs at agent restart.
- Headless env gap: `~/.bashrc:6` returns early for non-interactive shells;
  `GITHUB_PERSONAL_ACCESS_TOKEN` is derived at `~/.bashrc:27-35` from
  `gh auth token`, so a cron-launched run gets no GitHub token unless the
  wrapper derives it itself. `.mcp.json` needs that var for the GitHub MCP.
- Permissions: `.claude/settings.json:1-78` allowlists read ops, `git
  fetch|diff|status|add|commit`, Linear MCP, read-only GitHub MCP — no push, no
  `gh`, no server starts. No per-run spend or turn cap exists in Claude Code;
  cost is post-hoc via `--output-format json` → `total_cost_usd`.
- **Permission glob verified empirically** (this session): with
  `deny: ["Bash(echo --force *)"]`, `echo --force x` was denied and
  `echo --force-with-lease x` ran — so `Bash(git push --force *)` blocks raw
  force-push without breaking ship-work's `--force-with-lease` rebase.
- Two `claude -p` processes have no built-in mutual exclusion; `flock` required.
- Linear: no `agent:*` labels exist (only Triage/Bug/Feature/Improvement/
  "Awaiting Ryan Review"). **All Linear comments and labels are
  workspace-visible — unsuitable for private plan review.**
- `gh` is authed on this machine (the bashrc token derivation works), so a
  private GitHub repo is reachable from both bash and the GitHub mobile app
  with zero new credentials.
- `coder-packages` (`/home/coder/coder-packages`, clean on `main`) has the
  idempotent-installer pattern to copy (`scripts/install-hooks.sh`, `--check`
  mode) and `flake.nix:31` `extraAttrs` for adding nix packages.

**What does not exist** (all must be created):

- No headless flag, ask→fallback protocol, or status-file contract in any skill.
- No orchestrator, poller, brief, notify script, private review channel.
- No cron substitute, tmux, boot persistence, lock, budget or kill-switch state.
- No unattended permission profile; no `agent:*` labels; no inbox repo.

## Approach

Keep the three skills as the only things that do real work; wrap them. A thin
bash orchestrator (`ap-cycle.sh`) fires from supercronic inside a tmux session
every 20 minutes around the clock, takes an exclusive `flock`, and runs three
stages:

1. **Poll** (haiku): read the queue and the inbox, emit strict JSON —
   `{action: implement|replan|plan|none, issue, planPath?, feedback?}`.
   Priority: approved plans, then feedback/answers (re-plan), then new
   `agent:queue` issues.
2. **Act** (full model): `claude -p "/plan-issue ENG-X --headless"`, or
   `claude -p "/implement-plan <path> --headless"` followed on success by
   `claude -p "/ship-work <path> --headless --no-merge"` — each with
   `--output-format json` and the dedicated `--settings` autopilot profile.
3. **Report** (bash): parse the run's `status.json`, reconcile inbox state,
   ping the phone on `NEEDS_HUMAN`/`FAILED`, append cost to the day's ledger.

**Private review channel:** a new private GitHub repo, `haroun-mj-ai/
autopilot-inbox`. Each delegated Linear issue gets one inbox issue; the full
plan markdown is posted there, readable in the GitHub mobile app. Approval is a
`go` comment (owner only); any other comment is treated as feedback and triggers
a re-plan that quotes it. Questions the agent cannot answer are asked on the
inbox issue (private), never on Linear. The inbox issue's own labels
(`planning → plan-review → building → ready-to-test | needs-input | failed`)
are the pipeline state machine — free to churn, invisible to the team. Linear
keeps only its normal public footprint: `agent:queue` (applied by Haroun to
delegate), assignee + `In Progress` on claim, a PR-link comment +
`agent:ready-to-test` at the end (PRs are team-visible on GitHub anyway).
Status is never set to `Staging` or `Done` headlessly (`Staging` means merged,
per `AGENTS.md:80`).

Headless mode is a documented protocol added to the skills: under `--headless`,
every "ask the human" point maps to either a documented default or "post the
question to the inbox issue, write `status: NEEDS_HUMAN`, exit". Every run ends
by writing `$AP_RUN_DIR/status.json` (`DONE | NEEDS_HUMAN | FAILED`, plus
issue, phase, plan_path, pr_urls, question, detail). The plan-gate is preserved
exactly: headless plan-issue ends at inbox `plan-review` + a phone ping; only
the owner's `go` lets a later cycle build.

**Non-interference contract** (Haroun works interactively at any hour):
autopilot only ever touches issues he labeled `agent:queue`; all its work
happens in its own worktrees and branches (main checkout and open editors
untouched); it never binds the baseline ports (5173/8000) he tests against and
releases its transient ports after QA; `ap pause` is the one-command override.
No CPU/load yielding — accepted that heavy runs share the box, as long as
Coder/VSCode access itself is unaffected (it is: access is network-side, not
load-gated).

Boot persistence without systemd: idempotent `ap up` (tmux session running
supercronic) plus a managed block in `~/.bashrc` re-running `ap up` on any
interactive login (self-heal), plus — if Haroun has Coder template admin — one
line in the template `startup_script`. Serial-by-flock; kill switch
`~/.autopilot/pause`; auto-pause + ping after 2 consecutive failures or when
the per-day budget is spent.

Rejected alternatives: GitHub Actions runner (loses local Mongo/e2e/server
handover); one always-on interactive session (a context window cannot span a
day, and a crash kills the scheduler); Linear webhooks (needs an inbound
endpoint; 20-min polling suffices); approval via Linear comments (team-visible
— rejected by the user); approval via ntfy reply-topics (plan markdown is
unreadable in a notification app, topic auth is weaker than the already-authed
private repo).

## Work units

### U0: Reconcile skill drift

- **Repo:** root (this worktree)
- **Depends on:** none; blocks U3a-c
- **Files:** `.claude/skills/{plan-issue,implement-plan,ship-work}/SKILL.md`
  (+ any sibling files that differ)
- **Change:** copy the newer versions from `/home/coder/coder-packages/claude/
  skills/` over the tracked copies in this worktree; verify with `diff -rq`
  that the three dirs match coder-packages exactly; commit as its own commit
  ("sync skills to newest (coder-packages bffcaff)") so the headless edits in
  U3 diff cleanly against the real current text. Note in the commit body that
  the repo copy is canonical from here on.
- **Tests:** `diff -rq` clean between the two trees for the three skills.
- **Done when:** worktree copies match coder-packages; committed separately.

### U1: Autopilot runtime scripts

- **Repo:** `coder-packages` (new dir `autopilot/`)
- **Depends on:** none (contract shared with U3; keep `status.json` shape in
  sync with the protocol file)
- **Files:** `autopilot/bin/ap-cycle.sh`, `autopilot/bin/ap-notify.sh`,
  `autopilot/bin/ap-env.sh`, `autopilot/bin/ap` (up/down/status/pause/resume),
  `autopilot/crontab`, `autopilot/settings/autopilot.json`,
  `autopilot/tests/test_cycle.sh`
- **Change:**
  - `ap-env.sh`: sourceable; derives `GITHUB_PERSONAL_ACCESS_TOKEN=$(gh auth
    token)` non-interactively; sources `~/.autopilot/env` (user config:
    `NTFY_TOPIC` and/or `SLACK_WEBHOOK_URL`, `AP_MAX_ISSUES_PER_DAY` default 3,
    `AP_MAX_DAY_COST_USD` default 50, `AP_TZ`, `AP_INBOX_REPO` default
    `haroun-mj-ai/autopilot-inbox`); exports `AP_RUN_DIR`.
  - `ap-notify.sh "<title>" "<body>" [url]`: POSTs to ntfy topic and/or Slack
    webhook (whichever configured; both if both; click-through URL when given);
    exits 0 when unconfigured (logs instead).
  - `ap-cycle.sh`: exit if `~/.autopilot/pause` → `flock -n ~/.autopilot/lock`
    or exit → budget check against today's ledger (issues acted on + summed
    `total_cost_usd` since local midnight, `AP_TZ`) → stage 1 poll (haiku,
    `--json-schema`-enforced) → stage 2 act (full model,
    `--settings autopilot.json`, `--output-format json`; capture
    `total_cost_usd`, `session_id`) → stage 3 reconcile: read
    `$AP_RUN_DIR/status.json`; **the wrapper is authoritative for terminal
    states** — on `FAILED` *or* missing status.json it sets the inbox issue
    label to `failed`, comments what it knows (stderr tail, denial string if
    present), and pings; on `NEEDS_HUMAN` it verifies the question landed on
    the inbox issue (posts it via `gh` if the run died before doing so) and
    pings with the issue URL; on `DONE` it trusts the skill's own label/comment
    writes → append `{ts, issue, phase, status, cost, session_id}` to
    `~/.autopilot/runs/YYYY-MM-DD.jsonl` → 2 consecutive failures = auto-pause
    + ping.
  - `crontab` (supercronic): `*/20 * * * * ap-cycle.sh`, `0 7 * * *
    ap-brief.sh`, with `CRON_TZ` from `AP_TZ` at install.
  - `settings/autopilot.json`: `defaultMode: "dontAsk"`; allow: scoped git
    (fetch/status/diff/log/add/commit/worktree/rebase/push/mv/branch),
    `Bash(gh issue *)`, `Bash(gh api *)` (inbox reads/writes),
    npm/npx/poetry/pytest/playwright, uvicorn + vite starts,
    Edit/Write/Read/Grep/Glob/WebFetch, Linear MCP
    (get_issue/list_comments/list_issues/list_projects/save_issue/save_comment),
    GitHub MCP `create_pull_request`, `pull_request_read`,
    `update_pull_request`; deny: `mcp__github__merge_pull_request`,
    `Bash(git push --force *)` (verified: does not catch `--force-with-lease`),
    `Bash(git push origin main*)`, `Bash(git push origin dev*)`,
    `Bash(git reset --hard *)`, destructive Mongo tools. **Do not allow
    `update_pull_request_branch`** — ship-work explicitly avoids it
    (`ship-work/SKILL.md:195-198`) and allowing it is a footgun under dontAsk.
- **Tests:** `test_cycle.sh` runs `ap-cycle.sh` with stub `claude`, `gh`, and
  `ap-notify.sh` on `PATH` (record argv, emit canned JSON/status files) and
  asserts: pause skips; concurrent second invocation exits (flock); day-budget
  cap stops stage 2; stub `NEEDS_HUMAN` pings with issue URL; stub `FAILED`
  *with* a written status.json still flips the inbox label (wrapper
  authority); crash (no status.json) → `failed` label + ping; ledger line
  appended, valid JSON, dated per `AP_TZ`. `shellcheck` clean.
- **Done when:** `bash autopilot/tests/test_cycle.sh` green; `shellcheck
  autopilot/bin/*` clean; `supercronic -test autopilot/crontab` accepts it.

### U2: Installer and boot persistence

- **Repo:** `coder-packages`
- **Depends on:** U1
- **Files:** `scripts/install-autopilot.sh`, `flake.nix` (add tmux +
  supercronic to `extraAttrs`), `autopilot/README.md`
- **Change:** idempotent installer modeled on `scripts/install-hooks.sh` with
  `--check`: `nix profile install` tmux + supercronic if missing; create
  `~/.autopilot/{runs,briefs,logs}`; seed `~/.autopilot/env` from a template
  (never overwrite existing); symlink `autopilot/bin/*` into `~/.local/bin`;
  write a fenced managed block into `~/.bashrc` (after the interactive guard —
  self-heal only needs interactive logins) running `ap up --quiet`; `ap up` =
  create-or-reuse tmux session `autopilot` running `supercronic <crontab>`;
  `ap status` = tmux liveness, pause state, last 3 ledger lines, gap warning
  if no cycle ran in >1h; README covers: daily flow, the approval protocol,
  `ap pause`, tuning the allowlist after a denial, and that the repo skill
  copies are canonical (coder-packages `claude/` is a stale mirror — follow-up
  to remove it).
- **Tests:** installer twice → second run no-op, `--check` green; bashrc block
  present exactly once; `ap up && ap status` shows a live session.
- **Done when:** `--check` exits 0 on a converged machine, non-zero before.

### U3a: Headless protocol + plan-issue

- **Repo:** root (this worktree)
- **Depends on:** U0
- **Files:** new `.claude/skills/autopilot-protocol.md`,
  `.claude/skills/plan-issue/SKILL.md`
- **Change:** the protocol file defines: the `--headless` argument; status
  vocabulary `DONE | NEEDS_HUMAN | FAILED`; `status.json` shape
  (`{status, issue, phase, plan_path, pr_urls[], question, detail}`) written
  to `$AP_RUN_DIR` (fallback `~/.autopilot/runs/adhoc/`); the inbox contract
  (repo from `AP_INBOX_REPO`; one issue per Linear issue, title `ENG-<id>:
  <title>`; state labels `planning/plan-review/building/ready-to-test/
  needs-input/failed`; plan markdown posted as the body or a comment; owner
  comment `go` = approval, any other owner comment = feedback for re-plan);
  the ask→fallback rule (documented default if one exists, else inbox question
  + `needs-input` + `NEEDS_HUMAN` exit); what stays on Linear (claim =
  assignee + In Progress; final PR comment + `agent:ready-to-test`; never
  plan content, never questions, never Staging/Done). plan-issue headless
  section maps its ask points: duplicate-ticket match → plan the existing
  issue, note it in the inbox; thin description → NEEDS_HUMAN (question to
  inbox); project coin-flip → first matching rule in the priority order,
  record the assumption in the plan; under `--headless` used by autopilot the
  input is always an existing issue id (never free-text creation); end state →
  create/update the inbox issue with the full plan markdown, label
  `plan-review`, write status.json, and per protocol the wrapper pings.
  Re-plan entry: when invoked with feedback text, treat it as new requirements
  from the requester and revise the existing committed plan in place.
- **Tests:** prose contract; pinned from the other side by U1's stub asserts
  (same status.json shape) and U6 live smoke.
- **Done when:** plan-issue references the protocol; shapes match U1's tests.

### U3b: implement-plan headless

- **Repo:** root (this worktree)
- **Depends on:** U0, U3a (protocol exists)
- **Files:** `.claude/skills/implement-plan/SKILL.md`
- **Change:** headless section: plan path is always explicit, never inferred
  (`:50-51` ask removed in headless); open BLOCKING → NEEDS_HUMAN via inbox;
  uncommitted unrelated work in a target repo → NEEDS_HUMAN (do not work
  around); **server policy**: run the full QA including the four-server
  comparison per the (newer, U0-synced) handover section, then **stop the
  changed-pair servers**, keep/restore the baseline pair (5173/8000), and
  record the exact relaunch commands (worktree paths, ports) in status.json
  `detail` and an inbox comment — this is what Haroun runs (or asks his
  interactive session to run) in the morning to "open the dev server with the
  fix"; end state → inbox label stays `building`, status.json `DONE` with the
  QA summary; ship stage follows in the same cycle.
- **Tests:** prose; U6 verifies teardown left only baseline ports bound
  (`ss -ltnp` before/after).
- **Done when:** section present; interactive behavior text untouched.

### U3c: ship-work headless

- **Repo:** root (this worktree)
- **Depends on:** U0, U3a
- **Files:** `.claude/skills/ship-work/SKILL.md`
- **Change:** headless section: `--headless` implies `--no-merge`,
  non-negotiable; each of the six hard stops (`:24-46`) exits NEEDS_HUMAN with
  the stop reason posted to the inbox issue (not the terminal); success → PR
  URLs commented on the inbox issue **and** a PR-link comment + label
  `agent:ready-to-test` on the Linear issue (its one public write beyond the
  claim), Linear status stays In Progress, status.json `DONE` with `pr_urls`;
  plan archiving (`docs/plans/` → `completed/`) is deferred to the human merge
  — note that the interactive `/ship-work` merge run handles it as today.
- **Tests:** prose; U6 live smoke.
- **Done when:** section present; the merge step is unreachable under
  `--headless` by construction of the text.

### U4: `autopilot-poll` and `daily-brief` skills

- **Repo:** root (this worktree) + one wrapper script in `coder-packages`
- **Depends on:** U3a (protocol)
- **Files:** `.claude/skills/autopilot-poll/SKILL.md`,
  `.claude/skills/daily-brief/SKILL.md`,
  `coder-packages/autopilot/bin/ap-brief.sh`
- **Change:** `autopilot-poll` (haiku-sized): gather, in priority order —
  (1) inbox issues labeled `plan-review` with a new owner comment: `go` →
  `{action:"implement", issue, planPath}` **claimed immediately in the same
  cycle** (swap inbox label to `building`); any other owner comment →
  `{action:"replan", issue, feedback}` (label back to `planning`);
  (2) inbox issues labeled `needs-input` with a new owner comment →
  `{action:"replan"}` with the answer as feedback; (3) Linear `agent:queue`
  issues with no inbox issue yet → `{action:"plan", issue}` (create the inbox
  issue, label `planning`, claim on Linear: assignee + In Progress); else
  `{action:"none"}`. Stale-claim sweep: inbox `planning|building` with no
  ledger entry in 3h **and** no lock held → label `failed` + inbox comment.
  Emit only the JSON object (wrapper enforces via `--json-schema`).
  `daily-brief`: read `~/.autopilot/runs/*.jsonl` since the last brief +
  current inbox labels; digest: awaiting-approval (with inbox links) / ready
  to test (PR links + relaunch commands) / needs input (the questions) /
  failed / total cost vs budget / scheduler-gap warning; write
  `~/.autopilot/briefs/YYYY-MM-DD.md` and print it. `ap-brief.sh`: run
  `claude -p --model haiku "/daily-brief"`, send the output via `ap-notify.sh`.
- **Tests:** poll output schema is exercised by U1's stub tests; brief in U6.
- **Done when:** a manual poll against a test inbox issue returns schema-valid
  JSON and performs the documented label swaps.

### U5: Inbox repo, Linear labels, machine bring-up

- **Repo:** none (GitHub, Linear, machine state)
- **Depends on:** U2, U4
- **Change:** `gh repo create haroun-mj-ai/autopilot-inbox --private` with the
  six state labels; create the two Linear labels (`agent:queue`,
  `agent:ready-to-test`) via `mcp__linear-server__create_issue_label`; run
  `install-autopilot.sh`; fill `~/.autopilot/env` (user supplies `NTFY_TOPIC`
  — an unguessable topic string — and/or `SLACK_WEBHOOK_URL`, plus `AP_TZ`);
  `ap up`; `ap-notify.sh "autopilot" "hello from the workspace"` and the user
  confirms the ping lands on their phone.
- **Done when:** inbox repo private and labeled; Linear labels exist;
  `ap status` live; user confirms the phone ping.

### U6: End-to-end smoke

- **Repo:** none (operational)
- **Depends on:** U0-U5
- **Change:** file a deliberately trivial sandbox Linear issue (docs typo),
  label `agent:queue`; force one cycle by hand → verify inbox issue appears
  with the full plan, label `plan-review`, phone pinged with the link; comment
  `go` from the GitHub mobile app; force another cycle → verify implement +
  ship `--no-merge` produce a PR, `agent:ready-to-test` + PR comment on
  Linear, relaunch commands on the inbox issue, only baseline ports left bound
  (`ss -ltnp`), ledger entries with real costs; run `ap-brief.sh` → digest on
  the phone. Also verify the feedback path once: comment a change request
  instead of `go` on a second sandbox issue and confirm a revised plan
  appears. Clean up: close sandbox issues/PRs/branches/worktrees.
- **Done when:** queue → private plan review → phone approval → PR → brief has
  run end-to-end without a terminal touch after the initial labeling.

## Test strategy

Deterministic core: U1's stub harness (`claude`, `gh`, notify stubs) is the
contract test — the orchestrator is bash, so every branch (pause, flock,
budget, wrapper-authority on FAILED/crash, ping-with-URL) is asserted without
spending tokens. `shellcheck` + `supercronic -test` keep scripts and crontab
honest. The skill-side protocol is prose executed by a model, so it is pinned
from both sides: stub tests assert the exact `status.json` shape and label
transitions the protocol promises, and U6 proves one live pass honors them,
including the feedback/re-plan path. U6 costs are bounded by trivial sandbox
issues.

## Edge cases

- **Workspace restarts mid-run:** flock dies with the process (no stale lock);
  the claimed inbox issue sits at `planning|building` with a ledger gap — the
  3h stale-claim sweep flags it `failed` with a comment. Scheduler itself
  self-heals on next interactive login (`~/.bashrc` block) — see open question
  on TTL for the no-login-overnight case.
- **Run fails legitimately (status.json written, FAILED):** wrapper — not the
  skill — is authoritative: flips inbox label to `failed`, comments, pings.
  Same path as a crash, so no state can be stranded either way.
- **User approves while a build is running:** serial flock; next cycle claims
  it, and implements-first ordering guarantees it beats new planning.
- **Queue empty:** stage 1 only (~cents/day at 72 haiku cycles).
- **Permission denial under `dontAsk`:** acting run fails fast → FAILED →
  denial string lands in the inbox comment + ledger → tune the allowlist next
  morning. Intended tightening loop.
- **Usage/plan limits exhausted:** `claude` exits non-zero → 2 consecutive
  failures auto-pause + ping. No thrash.
- **Port exhaustion:** U3b teardown; only the baseline pair persists.
- **User works interactively at any hour:** autopilot claims only
  `agent:queue`-labeled issues; own worktrees/branches; never binds 5173/8000;
  `ap pause` for anything invasive. CPU is shared by design (accepted).
- **Two issues touching one file:** worktrees isolate branches; semantic
  conflicts surface in ship-work's rebase/CI and become NEEDS_HUMAN.
- **Approval comment ambiguity:** only the repo owner's comments count; `go`
  (case-insensitive, exact word) approves; anything else is feedback →
  re-plan. Inbox is private, so no teammate can trigger anything.
- **Plan content in a private repo:** the inbox repo must stay private and
  personal (`haroun-mj-ai`), never under the team org.

## Interaction surface

- **The three skills** are shared team files on `dev` — teammates use them
  interactively. U0 syncs them forward (pure improvement, authored by Haroun
  today in coder-packages); U3a-c additions are strictly headless-gated; the
  interactive default behavior text is untouched.
- **Linear:** two new labels, prefix `agent:`; no collision (live list has 5
  labels). Public writes limited to today's normal interactive footprint
  (claim; one PR comment; a status that never exceeds In Progress).
  `AGENTS.md:80` Staging-means-merged convention preserved by never setting it
  headlessly.
- **`~/.bashrc`:** managed block appended after the interactive guard;
  interactive-only by design.
- **Ports:** baseline 5173/8000 reserved for the human; transient
  5174-5176/8001 released after QA. CORS allowlist (`_DEFAULT_CORS_ORIGINS`,
  frontend 5173-5176) unchanged.
- **roborev:** unchanged; runs inside headless implement-plan as today.
- **coder-packages consumers:** `install-hooks.sh` untouched; new installer is
  additive; `flake.nix` gains two packages in `extraAttrs`.
- **Tenancy/roles/real-time/layout:** none — no app code changes (checked: no
  unit touches `backend/` or `frontend/`).

## Risks and open questions

- **Workspace auto-stop TTL** — unverified (CLI not logged in; user checking
  the dashboard). Non-blocking for the build, **blocking for go-live**: if the
  workspace sleeps, autopilot sleeps. Fallbacks if TTL can't be disabled:
  Coder template `startup_script` line (needs admin) or an external keep-alive.
- **Notification channel** — user supplies `NTFY_TOPIC` and/or
  `SLACK_WEBHOOK_URL` at U5. Assumption if unanswered: ntfy.sh with an
  unguessable topic (zero server config).
- **Inbox repo owner** — assumed `haroun-mj-ai` (personal org). Confirm at U5.
- **Usage limits** — 24/7 runs share the subscription pool; watch the ledger
  for a week before raising `AP_MAX_ISSUES_PER_DAY` from 3.
- **`dontAsk` allowlist completeness** — first days will surface denials
  (FAILED + inbox comment). Expected; tune rather than pre-approve broadly.
- **Skill copy in coder-packages goes stale after U0** — README notes the repo
  is canonical; removing `coder-packages/claude/` is a follow-up, not in
  scope.

## Verification

1. `bash autopilot/tests/test_cycle.sh`, `shellcheck`, `supercronic -test`,
   `install-autopilot.sh --check` — all green.
2. U6's live loop, including the feedback/re-plan path and the
   only-baseline-ports-bound check.
3. First real day: queue 1-2 real issues; next morning check the brief against
   inbox/GitHub/Linear state; run interactive `/ship-work` and confirm it
   merges the autopilot-opened PRs cleanly and archives the plan.
4. Regression indicator: a ledger gap >1h — surfaced by both `ap status` and
   the daily brief.

## Out of scope

- Merging autonomously (permanent human gate); anything touching `main`.
- Parallel issue processing (single Mongo/port budget; revisit later).
- Linear webhooks / event-driven triggers; phone-initiated cloud sessions.
- Removing the now-stale `coder-packages/claude/` mirror (follow-up).
- Auto-triage of unlabeled issues (v2: propose plans-of-attack on new issues).

## Design review

- **Verdict:** SOUND WITH FIXES (plan-critic dry run) — reconciled below.
- **Raised and fixed:**
  - The implement-plan "four servers / :487-527" citation did not exist in the
    dev-tracked copy — root cause was real skill drift (coder-packages holds
    newer versions of all three skills). Became U0, and the server-teardown
    design (U3b) now explicitly builds on the U0-synced text.
  - A legitimate `FAILED` run (status.json written) stranded its state label:
    the 3h sweep only caught crashes. Fixed by making the wrapper
    authoritative for all terminal states (U1 stage 3 + a stub test pinning
    it).
  - `go`-comment approval was ambiguous between same-cycle and next-cycle
    build. Pinned: the poll claims it immediately in the same cycle.
  - `update_pull_request_branch` removed from the allowlist (ship-work
    explicitly avoids it; footgun under dontAsk).
  - "Per-night" budget semantics on a 24/7 system: superseded by the user's
    own clarification — full rebrand to autopilot with per-day budgets.
  - U3 flagged as context-heavy for one sweep: split into U3a/U3b/U3c, one
    skill file per unit.
- **Verified empirically after the critic could not:** the
  `Bash(git push --force *)` deny pattern does not match `--force-with-lease`
  (live test with a deny rule on this machine, this session).
- **Raised and rejected:** none.
- **Superseded by user input after the critic ran:** plan review moved from
  Linear comments (team-visible) to the private inbox repo; the Linear label
  state machine shrank to two public labels; the load-yielding idea was
  dropped (user: CPU sharing is fine, only access matters).
- **Could not be checked** (by the critic; noted): live Linear label list
  (verified by me via MCP this session — 5 labels, no `agent:*`), Coder TTL
  (open question), `total_cost_usd`/`session_id` JSON fields (asserted by
  docs; U1's stubs make the wrapper resilient to their absence).

### Build-stage fixes (spec audit + roborev, 2026-08-12)

- **Symlink path resolution (audit, high):** the bin scripts resolved their
  own directory via `dirname $BASH_SOURCE`, which under the installer's flat
  `~/.local/bin` symlinks pointed at the wrong tree — `ap up` produced a
  dead tmux session and cycles would pass a nonexistent `--settings` path.
  Fixed with `readlink -f`; five new test cases (9-13) cover the symlinked
  layout, `AP_TZ` ledger dating, `CRON_TZ` rendering, and the FAILED-comment
  stderr contract.
- **`CRON_TZ` templating (audit):** the crontab is now a template; `ap up`
  renders it to `$AP_HOME/crontab.rendered` with `CRON_TZ=$AP_TZ`.
- **Plan-path guarantee (roborev, high):** nothing established that the
  inbox plan post contains the plan path, breaking approval→build. The
  protocol now requires every plan post to begin with `Plan file: <abs
  path>`; poll extracts it there with a filesystem fallback, and degrades
  to `needs-input` instead of emitting a broken implement action.
- **`needs-input` phase routing (roborev, medium):** NEEDS_HUMAN comments
  now begin with `Phase: plan|implement|ship`. Poll replans on plan/
  implement answers; ship-phase stops are never auto-actioned — they wait
  for the owner's interactive `/ship-work`, and the daily brief marks them
  so.
- **Coder TTL resolved at build time:** `coder schedule stop haroun manual`
  accepted — the workspace no longer auto-stops (was: 1-day TTL).

### Post-build user amendments (2026-08-12)

- **1-minute deterministic pre-scan:** cycles now fire every minute; a
  zero-token bash scan (pure `gh`) decides whether to wake the haiku poll.
  A full poll still runs every `AP_FULL_POLL_INTERVAL_MIN` (30) as the
  stale-claim-sweep safety net.
- **Inbox-only intake (supersedes the `agent:queue` Linear label):** the
  owner delegates by creating an issue titled `ENG-<id>` in the private
  inbox repo; an open inbox issue with no state label is a new delegation.
  Linear is never polled — its API key was revoked; Claude-side Linear MCP
  writes (claim, PR comment, `agent:ready-to-test`) are unchanged. The
  `agent:queue` label exists in Linear but is dead.
