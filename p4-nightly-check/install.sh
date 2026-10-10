#!/usr/bin/env bash
# Writes (or refreshes) the managed ~/.bashrc block that keeps the
# p4-nightly-check scheduler alive across workspace restarts, then starts it.
#   install.sh            install / refresh
#   install.sh --remove   remove the block and stop the scheduler
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RC="$HOME/.bashrc" START="# >>> p4-nightly-check >>>" END="# <<< p4-nightly-check <<<"
BODY="# Daily read-only review of prod's nightly action-item cleanup. See $HERE/README.md
[[ \$- == *i* ]] && [ -f $HERE/ensure.sh ] && bash $HERE/ensure.sh"
[[ "${1:-}" == --remove ]] && BODY=""
python3 - "$RC" "$START" "$END" "$BODY" <<'PY'
import re, sys
rc, start, end, body = sys.argv[1:]
text = open(rc).read()
pat = re.compile(re.escape(start) + r".*?" + re.escape(end) + r"\n?", re.S)
block = f"{start}\n{body}\n{end}\n" if body else ""
text = pat.sub(block, text) if pat.search(text) else (text.rstrip("\n") + "\n\n" + block if block else text)
open(rc, "w").write(text)
PY
if [[ "${1:-}" == --remove ]]; then
  tmux kill-session -t p4-nightly-check 2>/dev/null || true
  echo "removed"
  exit 0
fi
bash "$HERE/ensure.sh"
sleep 1
echo "installed; scheduler: $(tmux ls 2>/dev/null | grep p4-nightly-check || echo NOT RUNNING)"
