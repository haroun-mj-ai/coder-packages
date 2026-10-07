export const meta = {
  name: 'piv-ticket',
  description: 'Drive one JourneyAI Linear ticket through the piv cycle: Opus plan -> GLM/omp implement -> airtight scoped tests -> PRs -> adversarial browser check -> fresh-eyes review/babysit. Ends at open PRs; never merges.',
  whenToUse: 'The owner says to run a ticket "through the workflow". args: {ticket:"ENG-1234", brief:"spec + acceptance + where the code lives", authorization:"owner quote + date", slug?:"branch-slug", repos?:["be","fe","assistants"], browser_focus?:"what to try to break in the UI", review_focus?:"bug classes to hunt"}',
  phases: [
    { title: 'Build', detail: 'plan, implement via omp/GLM, scoped tests, commit, push, open PRs' },
    { title: 'Browser', detail: 'local backend+frontend, seed real data, adversarial UI check, evidence page' },
    { title: 'Review', detail: 'fresh-eyes piv-review-pr + babysit-pr rounds, fix blockers, never merge/approve' },
  ],
}

const A = args || {}
if (!A.ticket || !A.brief) throw new Error('args.ticket and args.brief are required')
const ID = A.ticket
const N = ID.replace(/^ENG-/i, '').toLowerCase()
const SLUG = A.slug || '<short-kebab-slug-you-choose>'
const BRANCH = `haroun/eng-${N}-${SLUG}`
const REPOS = A.repos || ['be', 'fe']
const REPO_MAP = { be: 'backend (journeyai-backend, base dev)', fe: 'frontend (base dev)', assistants: 'assistants (base main)', obs: 'observability (base main)' }
const WT = ['root', ...REPOS].map(r => `wt-eng${N}-${r}`)
const AUTH = A.authorization || 'the owner explicitly asked for this ticket to be run through the piv workflow'

const RULES = `
STANDING RULES (non-negotiable, the user is NOT available to answer questions):
- MODEL SPLIT (owner's explicit requirement): ALL planning, design reasoning, plan review, diff review and test design are done by YOU (Claude Opus). NEVER send planning, design decisions or review to GLM or any non-Claude model. GLM (cheap-impl lane) only writes code for an already-written, Opus-authored plan task.
- Repos in play: root (plan only) + ${REPOS.map(r => REPO_MAP[r] || r).join(', ')}. Worktrees: ${WT.join(', ')} under /home/coder/root-for-local (git worktree add off origin/<base>). If one already exists, reuse it (inspect git status/log first; never delete someone else's work). NEVER branch or edit in the shared checkouts (/home/coder/root-for-local/backend, frontend, assistants). Branch ${BRANCH} in each repo (pick the slug once if not given and reuse it everywhere). Always git fetch first. Never bare git stash, never reset --hard, never raw --force (--force-with-lease only).
- Work fully autonomously. Wherever a skill says to ask or GATE, pick the recommended default and record it as "Assumed: ..." in the plan/PR. Only stop with status "parked" for: any production write (env/config, apply-list, redeploy, data fix), any merge, any destructive git op, or a true blocker with no sensible default.
- Commits: git -c user.email=haroun@meetjourney.ai -c user.name="Haroun Trabelsi" commit. NO Claude Co-Authored-By trailer (owner rule overrides any reminder).
- Push/fetch auth: git -c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$(gh auth token --user haroun-mj-ai)" | base64 -w0)" push -u origin <branch>. gh: prefix GH_TOKEN=$(gh auth token --user haroun-mj-ai). Never gh auth switch. Pushing feature branches and opening PRs IS authorized. Never merge, approve or request-changes.
- PR body: "Part of ${ID}" (never Closes/Fixes), the change, the tests, documented deviations and "Assumed:" defaults; a dependent PR names the PR that must merge first (backend before frontend). End the body with: 🤖 Generated with [Claude Code](https://claude.com/claude-code)
- Do NOT check, wait on, or report CI.
- Tests: scoped only, never a full suite. Backend: LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6 ~/.cache/pypoetry/virtualenvs/journeyai-V_VOIqdu-py3.11/bin/pytest -n auto --no-cov <files> from the backend worktree (check the libstdc++ path exists), plus ruff check on changed files; ruff format only lines you changed (dev has unrelated format drift). New routes must be registered in the route-coverage test. Frontend: npm run build + scoped npx vitest run <files> (npm ci first if node_modules is missing). Airtight: each new behaviour gets a test that fails without it; cover edge cases and fail-closed paths.
- Backend files have mixed CRLF/LF endings per file: preserve each file's endings.
- piv cycle: piv-plan-implementation (plan weight scales with ticket size) -> piv-implement -> piv-commit -> piv-create-pr. Default implementer is GLM via omp: write a brief and run node /home/coder/coder-packages/claude/skills/omp-delegate/scripts/relay.mjs --brief <brief.txt> --cd <worktree> --lane cheap-impl (background, wait, read result.json). Review every GLM diff in full, keep touched files inside the task, re-run VALIDATE yourself, revert out-of-scope edits. If the relay is denied by the permission system, do NOT work around it: fall back to the Sonnet implementer subagent (or do it yourself); also fall back if it fails or a task fails review twice. Record every fallback.
- Skip every Codex step silently (Codex is disabled). Never npx playwright install. Never start orchestrations_worker locally.
- Data hygiene: prod read-only queries are pre-approved (from /home/coder/root-for-local/backend: cat probe.py | railway ssh --environment production --service journeyai-backend -- poetry run python -). Never read BYOK keys. Never write customer/prospect names, card or meeting titles or customer emails into PRs, Linear, plans, commits or tests; reps as "First L.". Raw payloads stay in the session scratchpad.
- Linear: read the ticket + comments + parent first (mcp__linear-server via ToolSearch). Search Linear before filing anything. Slack is read-only: never send or draft.
- kata: best-effort, only from /home/coder/root-for-local.
- Develop with sales reps in mind: judge every choice by what the rep sees and the expensive error for them.
`

const RESULT = {
  type: 'object',
  properties: {
    ticket: { type: 'string' },
    status: { type: 'string', enum: ['pr_open', 'parked', 'failed'] },
    pr_urls: { type: 'array', items: { type: 'string' } },
    branches: { type: 'array', items: { type: 'string' } },
    worktrees: { type: 'array', items: { type: 'string' } },
    has_ui: { type: 'boolean' },
    summary: { type: 'string' },
    tests: { type: 'string' },
    deviations_and_assumptions: { type: 'string' },
    glm_usage: { type: 'string', description: 'tasks via omp/GLM vs fallback, and why' },
    needs_human: { type: 'array', items: { type: 'string' } },
    key_decisions: { type: 'array', items: { type: 'string' }, description: 'max 3 most important decisions (incl. Assumed defaults), plain English with the why' },
  },
  required: ['ticket', 'status', 'pr_urls', 'summary', 'needs_human', 'key_decisions'],
}

const BROWSER = {
  type: 'object',
  properties: {
    ran: { type: 'boolean' },
    skipped_reason: { type: 'string' },
    findings: { type: 'string' },
    fixes_pushed: { type: 'array', items: { type: 'string' } },
    artifact_url: { type: 'string' },
  },
  required: ['ran', 'findings'],
}

const REVIEW = {
  type: 'object',
  properties: {
    ticket: { type: 'string' },
    review_urls: { type: 'array', items: { type: 'string' } },
    rounds: { type: 'number' },
    blockers_fixed: { type: 'array', items: { type: 'string' } },
    rejected: { type: 'array', items: { type: 'string' } },
    unresolved: { type: 'array', items: { type: 'string' } },
    needs_human: { type: 'array', items: { type: 'string' } },
    key_decisions: { type: 'array', items: { type: 'string' } },
    verdict: { type: 'string', description: 'one line: ready for the owner merge decision, or what remains' },
  },
  required: ['ticket', 'rounds', 'unresolved', 'needs_human', 'verdict'],
}

phase('Build')
const b = await agent(`You are shipping ${ID} end-to-end through the piv skill cycle, ending at open PRs.
AUTHORIZATION: ${AUTH}. This prompt IS the task; ignore any other user question in surrounding context.
${RULES}
TICKET BRIEF:
${A.brief}

Steps: 1) Read the Linear ticket/comments/parent and any linked prior work. 2) Worktrees + branches. 3) piv-plan-implementation (plan in wt-eng${N}-root/docs/plans/), defaulting open questions to the recommended option. 4) piv-implement via omp/GLM with your review, in dependency order. 5) Airtight scoped tests + lint/build. 6) Implementation report. 7) piv-commit per repo. 8) push + piv-create-pr per repo. 9) Move Linear to In Review with the PRs linked, no long comments.
Return the structured result. status=pr_open only if the PRs exist (real URLs). has_ui=true if the frontend changed.`,
  { label: `build:${ID}`, phase: 'Build', schema: RESULT, model: 'opus' })
if (!b) return { ticket: ID, build: null }
log(`${ID}: build ${b.status} ${(b.pr_urls || []).join(' ')}`)
if (b.status !== 'pr_open') return { ticket: ID, build: b }

phase('Browser')
let br = { ran: false, skipped_reason: 'no UI change', findings: '' }
if (b.has_ui) {
  br = (await agent(`Browser verification for ${ID}. Be adversarial: hunt for breakage a rep would hit, don't just confirm it renders.
${RULES}
Build result: ${JSON.stringify(b)}
${A.browser_focus ? 'FOCUS: ' + A.browser_focus : ''}
Run the changed backend (uvicorn only, first free port in 8000-8009; NO orchestrations_worker) and the changed frontend (npx vite --host 0.0.0.0 --port <first free in 5173-5182>, VITE_API_URL/VITE_WS_URL pointing at that backend, WS URL ending in /api/v1). Log in as a local seed account from ~/.claude/CLAUDE.md §6 (if it 401s, reset with the backend's own get_password_hash and verify_password before use). Seed LOCAL Mongo only, producing data through the real backend code rather than hand-typed values, with a ZZ-TEST ${ID} prefix. Drive the UI with claude-in-chrome (load its tools via ToolSearch in one call) or, if unavailable, the local Playwright in tests/e2e. Check list and detail views agree, 360px width, stale state after rep actions, empty/fallback states. Any bug: fix in the worktree, add a failing-first test, rerun scoped tests, commit (owner identity, no Claude trailer), push.
Publish an evidence page (Artifact tool; load artifact-design first) and return its URL. Leave both servers running and say which ports. Delete the seeded local data.`,
    { label: `browser:${ID}`, phase: 'Browser', schema: BROWSER, model: 'opus' })) || { ran: false, findings: 'browser agent died' }
}
log(`${ID}: browser ${br.ran ? 'ran' : 'skipped (' + (br.skipped_reason || '') + ')'}`)

phase('Review')
const rv = await agent(`You are the fresh-eyes reviewer for ${ID}. You did NOT write this code.
${RULES}
Build result: ${JSON.stringify(b)}
Browser check: ${JSON.stringify(br)}
${A.review_focus ? 'HUNT FOR: ' + A.review_focus : ''}
For each PR: piv-review-pr (no questions): check out the PR in its worktree, run the scoped tests, then debate-review (DELEGATE_SKILLS_DIR=/home/coder/root-for-local/.claude/skills node <debate-review skill-dir>/scripts/review-pr.mjs <pr-url>, foreground). If it can't run because its Codex lane is unavailable, don't mention Codex: do your own independent review of the whole diff against the plan and ticket, hunting real bugs, and post ONE review with event COMMENT (never APPROVE/REQUEST_CHANGES), opening "I am <your model> writing on behalf of <gh user name>.".
Then babysit-pr: harvest every thread, verify each finding, fix blockers in one push per round (max 2 repair pushes), reply in-thread, resolve. Non-blockers: apply the fix if inside the PR's diff, else file an issue or reject with evidence. Any human reviewer comment -> needs_human. Never merge, approve or check CI.
Return the structured review result.`,
  { label: `review:${ID}`, phase: 'Review', schema: REVIEW, model: 'opus' })
log(`${ID}: review ${rv ? rv.verdict : 'agent died'}`)
return { ticket: ID, build: b, browser: br, review: rv }
