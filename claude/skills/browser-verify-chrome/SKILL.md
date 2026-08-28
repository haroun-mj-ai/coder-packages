---
name: browser-verify-chrome
description: Personal variant of /browser-verify that drives your real, logged-in Chrome (via claude-in-chrome, bridged from this Coder workspace to your local machine) instead of Playwright's isolated Chromium. Use when you specifically need real session state — actual SSO logins, saved passwords, extensions, a specific Google account profile — that a clean Playwright profile won't have. Personal-only: depends on a bridge that only exists on this machine, so it is not the shared team default. If the bridge is down, this reports BLOCKED with revival steps rather than silently falling back to Playwright.
---

# Browser Verify (claude-in-chrome)

Drive the running local app — or any site requiring your real logged-in
session — in your actual Chrome via claude-in-chrome, as a step in local
testing. Same rigor as `/browser-verify` (the shared Playwright-based skill),
different transport. Use this one specifically when the task needs real
cookies/session/extensions Playwright's isolated profile doesn't have —
otherwise prefer `/browser-verify`, since it works without any personal setup
and is what the rest of the team also runs.

## Precondition: the bridge must be up

This only works because of a personal cross-machine bridge (this workspace
has no local Chrome). Before anything else, verify all three pieces are
alive:

1. **Workspace-side socat**: `ps aux | grep socat` should show
   `UNIX-LISTEN:/tmp/claude-mcp-browser-bridge-coder/bridge.sock,...fork TCP:localhost:9229`.
   If it's not running:
   ```bash
   SOCK_DIR="/tmp/claude-mcp-browser-bridge-${USER}"
   mkdir -p -m 700 "$SOCK_DIR"
   socat -d -d UNIX-LISTEN:"$SOCK_DIR/bridge.sock",mode=600,fork TCP:localhost:9229 &
   ```
2. **Local reverse SSH tunnel** (on the Windows machine): a terminal running
   `ssh -R 9229:localhost:9229 coder.haroun` must still be connected. This
   session can't verify this directly — ask the user to confirm the terminal
   is still open if a connection attempt fails.
3. **Local bridge-host script** (on the Windows machine): a terminal running
   `node bridge-host-windows.js` must still be running. Same caveat — ask the
   user to confirm if unsure.

If any of these are down, say so explicitly and ask the user to restart the
missing piece rather than silently switching to Playwright — that defeats
the reason this skill exists (real session state).

Reference: `https://github.com/haroun-mj-ai/claude-chrome-remote-bridge` has
the full setup writeup and both host-script variants.

## Selecting the right browser/profile

Two Chrome instances may show up as connected
(`mcp__claude-in-chrome__list_connected_browsers`). Confirm which is which by
navigating to `https://myaccount.google.com/` and reading the signed-in
account before assuming — don't guess from display name alone, since "Browser
1"/"Browser 2" labels aren't stable across reconnects. Known accounts as of
this setup:
- `harountrabelsi12@gmail.com` — personal profile
- `haroun@meetjourney.ai` — work profile

Pick whichever the task actually needs; when unclear, ask.

## Steps

1. **Load tools if deferred**:
   `ToolSearch("select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__read_page,mcp__claude-in-chrome__get_page_text,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__read_console_messages,mcp__claude-in-chrome__list_connected_browsers,mcp__claude-in-chrome__select_browser")`
2. **Confirm/select the browser** per above before doing anything else.
3. **Establish a tab**: `tabs_context_mcp` with `createIfEmpty: true`.
4. **Navigate to the feature under test** and exercise the golden path, edge
   cases, and adjacent surfaces the change could affect — same scenario
   discipline as `/browser-verify`: name the scenario list up front rather
   than winging it turn by turn.
5. **Check the console** via `read_console_messages` for new
   errors/warnings.
6. **Screenshot proof of each state.**
7. **Report a strict verdict** — PASS only if the golden path and every
   listed scenario actually passed with zero new console errors; otherwise
   FAIL or BLOCKED, naming exactly what failed.

## Known flakiness

- The bridge has no daemon/reconnect logic. If a call suddenly times out or
  errors with "Browser extension is not connected", the tunnel or
  `bridge-host-windows.js` likely died — ask the user to check both
  terminals before retrying.
- `select_browser` after a Chrome restart may need re-picking even if
  deviceId looks stable — verify via the Google account check, don't assume.
