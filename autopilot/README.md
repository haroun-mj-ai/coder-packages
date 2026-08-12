# Autopilot

A 24/7 scheduler that runs the three-skill delivery chain (`/plan-issue` →
`/implement-plan` → `/ship-work`) headlessly on this Coder workspace, so that
Haroun's own touchpoints shrink to: label an issue, review the plan privately
from his phone, test the result, and merge. It never merges anything itself —
that gate stays human, every cycle, forever.

## Install

```bash
cd coder-packages
./scripts/install-autopilot.sh          # idempotent, safe to re-run
./scripts/install-autopilot.sh --check  # report convergence, change nothing
```

This installs `tmux` and `supercronic` if missing, creates
`~/.autopilot/{runs,briefs,logs}`, seeds `~/.autopilot/env` (only if absent —
never overwritten), symlinks `autopilot/bin/*` into `~/.local/bin`, and adds a
managed self-heal block to `~/.bashrc` that runs `ap up --quiet` on every
interactive login.

## Configure `~/.autopilot/env`

The installer seeds this file with commented defaults; uncomment and fill in
what you need:

- `NTFY_TOPIC` — an unguessable topic string on [ntfy.sh](https://ntfy.sh).
  No account required: pick a random slug (e.g. `openssl rand -hex 16`) and
  subscribe to `https://ntfy.sh/<topic>` from the ntfy mobile app to receive
  pings.
- `SLACK_WEBHOOK_URL` — an "Incoming Webhook" URL from a Slack app
  (create one at <https://api.slack.com/apps> → your app → *Incoming
  Webhooks* → *Add New Webhook to Workspace*).
- `AP_MAX_ISSUES_PER_DAY` (default `3`) / `AP_MAX_DAY_COST_USD` (default
  `50`) — per-rolling-day budget caps, checked against
  `~/.autopilot/runs/YYYY-MM-DD.jsonl`.
- `AP_TZ` (default `UTC`) — timezone used for day boundaries (ledger,
  crontab, budget resets).
- `AP_INBOX_REPO` (default `haroun-mj-ai/autopilot-inbox`) — the private
  GitHub repo used for plan review.

At least one of `NTFY_TOPIC` / `SLACK_WEBHOOK_URL` must be set for pings to
actually go anywhere; unconfigured, `ap-notify.sh` just logs to
`~/.autopilot/logs/notify.log`.

## Daily flow

1. **Label** a Linear issue `agent:queue`. Autopilot claims it (assignee +
   `In Progress`) and plans it on the next cycle.
2. **Review privately.** The full plan markdown is posted as an issue in the
   private inbox repo (`AP_INBOX_REPO`) — readable from the GitHub mobile app,
   invisible to the rest of the team. A phone ping links you there.
3. **Approve or give feedback**, as a comment on that inbox issue:
   - Comment `go` (exact word, case-insensitive) to approve — the very next
     cycle claims it and starts building.
   - Comment anything else and it is treated as feedback: the next cycle
     re-plans in place, quoting your comment.
4. **Build happens unattended.** `implement-plan` runs full QA (including the
   four-server comparison), then tears down the changed-pair servers and
   leaves only your baseline (5173/8000) bound. `ship-work` opens a PR with
   `--no-merge`. You get a "ready to test" ping with the PR link and the exact
   relaunch commands (worktree paths, ports) — also posted on the inbox issue
   and, publicly, as a PR-link comment + `agent:ready-to-test` label on the
   Linear issue.
5. **Morning:** run the relaunch commands from the inbox issue, test against
   the running servers, then run the interactive `/ship-work` yourself to
   merge (autonomous merging is permanently out of scope) — it also archives
   the plan under `docs/plans/completed/`.

A daily brief (`ap-brief.sh`, 07:00 `AP_TZ` by default) pings a digest of
what's awaiting approval, ready to test, needs input, or failed, plus cost vs
budget and any scheduler gap.

## Controls

```bash
ap up        # start the tmux session running supercronic (idempotent)
ap down      # stop it
ap status    # tmux liveness, pause state, last 3 ledger lines, gap warning
ap pause     # touch ~/.autopilot/pause — cron entrypoints exit immediately
ap resume    # rm the pause file, reset the consecutive-failure counter
```

The pause file (`~/.autopilot/pause`) is the one-command override for
anything invasive you're about to do by hand — it does not touch a build
already in flight (the flock is per-cycle), but no new cycle starts while it
exists. Autopilot also auto-pauses itself (with a ping) after 2 consecutive
`FAILED` cycles.

Budgets are the other brake: `AP_MAX_ISSUES_PER_DAY` and
`AP_MAX_DAY_COST_USD` in `~/.autopilot/env`, checked against the day's ledger
before every acting cycle.

## Troubleshooting

- **Permission denials under `dontAsk`:** an acting run fails fast (`FAILED`),
  and the denial string lands both in the inbox issue's comment and in the
  day's ledger line. This is the expected tightening loop — extend the allow
  list in `autopilot/settings/autopilot.json` once you've seen what was
  denied, rather than pre-approving broadly up front.
- **A claim looks stuck** (inbox issue stuck at `planning`/`building`): the
  stale-claim sweep flags anything with no ledger entry in 3 hours and no
  held lock as `failed`, with a comment. This covers both a workspace restart
  mid-run and a legitimate crash.
- **Two consecutive failures:** autopilot auto-pauses and pings; `rm
  ~/.autopilot/pause` or `ap resume` once you've fixed the cause.
- **No cycles for a while:** `ap status` and the daily brief both surface a
  ledger gap over an hour as a warning — check the tmux session
  (`tmux attach -t autopilot`) and `~/.autopilot/logs/cycle.log`.

## A note on `coder-packages/claude/`

The three skills that autopilot wraps (`plan-issue`, `implement-plan`,
`ship-work`) are shared team files. **The canonical copies live in the
JourneyAI repo's `.claude/skills/`** — that is what teammates and this
pipeline both use. The `claude/` directory in this repo is a stale mirror
kept around from before the skills moved; it is not read by autopilot and is
slated for removal as a follow-up. Don't edit it expecting it to take effect.
