# p4-nightly-check

A daily, read-only review of what prod's nightly action-item cleanup did, at
08:40 America/New_York.

- `probe.py` runs inside the prod backend container over `railway ssh`. It is
  read-only: it asserts `RAILWAY_ENVIRONMENT_NAME == production` and only
  aggregates. Output is counts and 8-char id prefixes; no titles, model
  reasons, names or emails.
- `run.sh` feeds that JSON (plus yesterday's) to a tool-less headless Claude
  (Sonnet, $2 cap) with `prompt.md`. It writes
  `~/.p4-nightly-check/reports/<date>.{json,md}` (mode 600, never in a repo) and
  sends the headline to the desktop notify bridge.
- `crontab` + `ensure.sh` run it from `supercronic` in a detached tmux session
  (`p4-nightly-check`). `ensure.sh` is called from a managed `~/.bashrc` block,
  so the scheduler comes back after a workspace restart. It also runs today's
  check on login if the 08:40 run was missed.

```bash
./install.sh            # add the ~/.bashrc block and start the scheduler
./install.sh --remove   # remove it and stop the scheduler
./run.sh [YYYY-MM-DD]   # run once by hand
tail ~/.p4-nightly-check/run.log
```

Needs `railway` logged in (`railway whoami`) and `claude` logged in. A failure
sends a "FAILED" notification and is logged to `run.log`.

Retire it once the Trust Console has a nightly-cleanup view and the ENG-2531
morning alert is calibrated and on.
