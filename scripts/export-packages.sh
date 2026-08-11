#!/usr/bin/env bash
# Print this flake's extras as a markdown table, for pasting into README.md.
#
#   ./scripts/export-packages.sh
#
# The data comes from the `extraAttrs` set in flake.nix (via the extrasInfo
# output), NOT from the live `nix profile list`. Same reasoning as the base
# repo's version of this script: a running workspace accumulates hand-installed
# extras and drifts, so the flake is the source of truth and the profile is not.
set -euo pipefail

cd "$(dirname "$0")/.."

system=$(nix eval --raw --impure --expr 'builtins.currentSystem')

nix eval ".#extrasInfo.${system}" --json \
  | python3 -c '
import json, sys

rows = json.load(sys.stdin)
rows.sort(key=lambda r: r["name"])

print("| Package | Version | License |")
print("| --- | --- | --- |")
for r in rows:
    lic = "unfree" if r["unfree"] else "free"
    print(f'"'"'| `{r["name"]}` | {r["version"]} | {lic} |'"'"')
'
