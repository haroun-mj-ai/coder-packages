---
name: herdr-runs
description: >-
  Run long or background shell commands (dev servers, test suites, builds, watchers, delegate relays
  like pi-delegate/claude-delegate, anything you would otherwise start with run_in_background) in a
  visible herdr pane via `hrun`, so the user can watch them live. Use this BY DEFAULT whenever
  HERDR_ENV=1 and a command will run longer than ~20s or in the background — the user has given
  standing permission for this; it does not need to mention herdr. Skip it for quick commands.
metadata:
  version: 0.1.0
---

# herdr runs

The user wants nothing running hidden. When this session is inside herdr (`HERDR_ENV=1`), long and
background commands go to a **"runs" tab** in the current herdr workspace through `hrun`, instead
of the Bash tool's `run_in_background` or a hidden shell. The panes never take focus and stay open
afterwards, so the user can read or scroll them.

This is a standing user preference. It overrides the herdr skill's "only when the user mentions
Herdr" default **for running commands only** — it does not license closing, moving, or typing into
panes `hrun` did not create, and it does not change how agents or subagents are started.

## Use

```bash
# blocking: waits, prints only this run's output, exits with the command's exit code
hrun --label backend-tests --wait --timeout 600000 -- 'cd backend && poetry run pytest tests/foo -n auto'

# non-blocking (servers, watchers): returns at once with the pane id
hrun --label backend-8000 -- 'cd backend && make run-local'
herdr pane wait-output <pane-id> --match "Application startup complete" --timeout 120000
herdr pane read <pane-id> --source recent-unwrapped --lines 120

hrun --list     # run panes in this workspace
hrun --clean    # close run panes back at an idle prompt (keeps one, so the tab survives)
```

- Quote the command as **one argument**. It runs in a subshell in that pane, so `exit`, `cd` and
  env changes cannot break the pane.
- `--wait` exit codes: the command's own code; `124` = your timeout hit (the command keeps running in
  its pane — read it, don't re-run it); `3` = not inside herdr → fall back to the Bash tool as usual;
  `4` = 4 run panes already busy → wait or `--clean`.
- Always pass `--timeout` with `--wait` for anything that could hang. For a blocking Bash tool call,
  keep it under the tool's own timeout.
- Notifications fire on failure or runs of 60s+ by default; `--notify` forces one (use it for
  anything the user is waiting on), `--no-notify` silences it.
- Give every run a short `--label` that says what it is (`frontend-5173`, `pytest-orchestrations`).

## Delegates

To make a delegate visible without changing the delegate skills, launch its relay through `hrun`:

```bash
hrun --label pi-cheap-impl --notify --wait --timeout 3600000 -- \
  'node <skill-dir>/scripts/relay.mjs --brief /abs/path/brief.txt --cd /abs/repo --provider lunaroute --model glm-5.3 --timeout 1h'
```

Use absolute paths. Everything after that (read result.json, review the diff, re-run the gates,
commit) is unchanged.

## Housekeeping

Run `hrun --clean` when you finish a task that opened several run panes. Leave a pane open when the
user will want to read it (a failing test run, a server they're using).
