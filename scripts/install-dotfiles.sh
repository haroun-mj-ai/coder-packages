#!/usr/bin/env bash
# Restore personal tool configs from dotfiles/ onto a fresh workspace.
# omp models.yml is hand-written, so it is symlinked (edits land here).
# omp config.yml and hindsight coding-agent.json get rewritten by their tools,
# so they are copied only when missing — re-snapshot them by hand after changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HOME/.omp/agent" "$HOME/.hindsight"
ln -sfn "$ROOT/dotfiles/omp/models.yml" "$HOME/.omp/agent/models.yml"
[ -e "$HOME/.omp/agent/config.yml" ] || cp "$ROOT/dotfiles/omp/config.yml" "$HOME/.omp/agent/config.yml"
[ -e "$HOME/.hindsight/coding-agent.json" ] || cp "$ROOT/dotfiles/hindsight/coding-agent.json" "$HOME/.hindsight/coding-agent.json"
echo "dotfiles installed"
