---
name: browser-verify-chrome
description: Personal variant of /browser-verify that drives your real, logged-in Chrome (via claude-in-chrome, bridged from this Coder workspace to your local machine) instead of Playwright's isolated Chromium. Use when you specifically need real session state — actual SSO logins, saved passwords, extensions, a specific Google account profile — that a clean Playwright profile won't have. Personal-only: depends on a bridge that only exists on this machine, so it is not the shared team default. If the bridge is down, this reports BLOCKED with revival steps rather than silently falling back to Playwright.
context: fork
---

> **Runs forked (`context: fork`).** This skill runs as a separate agent so screenshots and page dumps stay out of the caller's context. You can't ask the user anything mid-run. Wherever this file says to ask the user, stop and return the question as your result, together with what you've verified so far.

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

Almost always only one Chrome instance is connected — no need to verify its
identity via a Google-account check before proceeding. If
`mcp__claude-in-chrome__list_connected_browsers` ever shows more than one
(this has happened rarely), ask the user which one to use rather than
guessing from display name alone ("Browser 1"/"Browser 2" labels aren't
stable across reconnects) — known accounts as of this setup:
- `harountrabelsi12@gmail.com` — personal profile
- `haroun@meetjourney.ai` — work profile

## Testing philosophy: hunt for breakage, don't just confirm the render

**Default posture is adversarial, not confirmatory.** The point of a real,
logged-in browser is that it can reach data states a clean fixture never
would — so use it for that. Checking that a DOM node's `aria-label` matches
the string you just read in the component's source is necessary but not
sufficient, and on its own it under-tests the actual risk: a real user never
hits one field in isolation, they hit combinations that accumulate over time
(a rep with data in an unusual shape, two features touching the same row,
an edge state nobody wrote a fixture for). "Does the code render what the
code says" is a weak claim — "does a plausible real state make this feature
lie to the user, show contradictory information, or produce a wrong number"
is the one worth spending a real browser on.

**Concrete case this was learned from (ENG-1377, 2026-09-20):** a first pass
confirmed a book-health ring's `aria-label` matched the seeded value — PASS,
technically correct, and it missed a real bug. A second, adversarial pass
looked at the WHOLE card instead of just the one element the diff touched,
and found the same card also rendered a second, contradictory line ("100%
short of quota") sourced from a completely different, un-updated function
reading a different set of fields on the *same row*. The bug only existed
in the combination — reading either field in isolation looked fine.

**How to apply this, concretely, every run:**
- Before opening the browser, ask "what real combination of fields/states
  could this row/page be in that a single happy-path fixture wouldn't
  produce?" — a rep with partial data, two features that both render off
  the same underlying row, a value at a rounding/currency/timezone boundary,
  a permission edge (can this user actually see this, or reach this via a
  URL they shouldn't guess), a state left over from a previous action.
  Write these down as the scenario list (per step 4 below) BEFORE clicking
  anything — don't wing it turn by turn.
- When you land on a page, read the WHOLE surface the change touches, not
  just the one element the diff added — an adjacent, unrelated-looking
  label can be quietly wrong even when the thing you changed is right.
- Prefer constructing a real, plausible adversarial data state over reading
  the happy path off a pre-seeded fixture — seed it yourself via Mongo/API
  the same way you would for `/airtight-test`, then revert it after.
- A screenshot you only glance at and move past is not the same as reading
  every line of text on it. Extract full card/section text (not just one
  `aria-label`) and actually read it for internal contradictions before
  calling a scenario PASS.

## Steps

1. **Load tools if deferred**:
   `ToolSearch("select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__read_page,mcp__claude-in-chrome__get_page_text,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__read_console_messages,mcp__claude-in-chrome__list_connected_browsers,mcp__claude-in-chrome__select_browser")`
2. **Establish a tab**: `tabs_context_mcp` with `createIfEmpty: true` — no
   browser-identity check needed first (see above).
3. **Name the scenario list up front**, per the philosophy above — golden
   path, plausible adversarial combinations, adjacent surfaces the change
   could affect — before touching anything. Don't wing it turn by turn.
4. **Navigate to the feature under test and drive every scenario on the
   list**, reading each surface in full (see above) — not just the field
   the diff touched.
5. **Check the console** via `read_console_messages` for new
   errors/warnings.
6. **Screenshot proof of each state — with `save_to_disk: true`.** Every
   screenshot that evidences a scenario verdict must be saved to a file
   (screenshots you only look at don't count as evidence), named
   `qa-<ticket>-NN-<what>.png`-style so the artifact step below can embed
   them. A verdict claimed without an on-disk screenshot behind it is not
   evidence.
7. **Report a strict verdict** — PASS only if the golden path and every
   listed scenario actually passed with zero new console errors and no
   internal contradictions anywhere on the surface; otherwise FAIL or
   BLOCKED, naming exactly what failed.
8. **Publish the evidence artifact — every run, not on request.** Build an
   HTML page (load the `artifact-design` skill first, then the Artifact
   tool) containing:
   - the ticket id and a one-line verdict banner (PASS / FAIL / BLOCKED);
   - the scenario table: each scenario, its result, and its embedded
     screenshot (as `data:` URIs — external images are CSP-blocked);
   - the hard evidence beyond pixels: DB rows queried (e.g. APIUsage /
     Message documents), exact cost math, console-error summary — a
     screenshot shows a thing rendered once; the data row proves what the
     system recorded;
   - a **"Gaps / not covered" section that is never empty-by-default**:
     enumerate what was NOT exercised and why (env constraints, missing
     keys, tunnel limits). A run that claims zero gaps must say how it
     knows that. This section is what makes the artifact usable as
     ticket-closure proof rather than a highlight reel.
   Post the artifact URL in the final report, and when the run verifies a
   Linear-tracked change, the URL belongs in the ticket's closing comment
   too.

## Known flakiness

- The bridge has no daemon/reconnect logic. If a call suddenly times out or
  errors with "Browser extension is not connected", the tunnel or
  `bridge-host-windows.js` likely died — ask the user to check both
  terminals before retrying.
- `select_browser` after a Chrome restart may need re-picking even if
  deviceId looks stable. Only worth an identity re-check (Google account) if
  more than one browser is actually listed as connected — the normal case is
  one, and no check is needed.
