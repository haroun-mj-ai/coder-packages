#!/usr/bin/env bash
# Idempotent: start the p4-nightly-check scheduler if it isn't running, then
# catch up today's report if the 08:40 ET run was missed (workspace was off).
# Called from the managed ~/.bashrc block that install.sh writes.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
STATE="${P4C_HOME:-$HOME/.p4-nightly-check}"
mkdir -p "$STATE" && chmod 700 "$STATE"
command -v tmux >/dev/null && command -v supercronic >/dev/null || exit 0
if ! tmux has-session -t p4-nightly-check 2>/dev/null; then
  tmux new-session -d -s p4-nightly-check \
    "TZ=America/New_York HOME=$HOME PATH=$PATH supercronic -passthrough-logs $HERE/crontab >>$STATE/cron.log 2>&1"
fi
setsid "$HERE/run.sh" --if-missing >/dev/null 2>&1 </dev/null &
