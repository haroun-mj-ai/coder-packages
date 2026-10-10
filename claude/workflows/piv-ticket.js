export const meta = {
  name: 'piv-ticket',
  description: 'Drive one JourneyAI Linear ticket through the piv cycle: prod ground truth -> Opus plan (routed: bug RCA / feature plan / epic slice) -> GLM implement -> PRs -> live verify -> prod deploy-readiness -> fresh-eyes review -> reconcile PRs+Linear. Ends at open PRs; never merges.',
  whenToUse: 'The owner says to run a ticket "through the workflow". args: {ticket:"ENG-1234", brief:"spec + acceptance + where the code lives", authorization:"owner quote + date", kind?:"bug|feature|chore|epic" (default: classified), slug?:"branch-slug", repos?:["be","fe","assistants"], browser_focus?:"what to try to break in the UI", review_focus?:"bug classes to hunt", prod_focus?:"what to check in prod"}',
  phases: [
    { title: 'Ground truth', detail: 'classify the ticket; read-only prod: reproduce, measure real data shape/volume' },
    { title: 'Plan', detail: 'Opus always: route to piv-investigate-issue (bug) / piv-plan-implementation (feature) / piv-slice-epic (epic); plan-critic dry-run' },
    { title: 'Build', detail: 'implement via omp/GLM (time-boxed), Opus diff review, pre-commit review, scoped tests, PRs' },
    { title: 'Verify', detail: 'UI: adversarial browser check. Backend-only: seed -> trigger -> check DB. Evidence page' },
    { title: 'Deploy readiness', detail: 'read-only prod: run the new logic against real prod data/volume; write the post-deploy check' },
    { title: 'Review', detail: 'fresh-eyes piv-review-pr + babysit-pr rounds, fix blockers, never merge/approve' },
    { title: 'Reconcile', detail: 'PR bodies + Linear brought up to date with evidence links, QA checklist, merge order, post-deploy check' },
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
- MODEL SPLIT (owner's explicit requirement): ALL planning, design reasoning, plan review, diff review and test design are done by Claude Opus. NEVER send planning, design decisions or review to GLM or any non-Claude model. GLM (cheap-impl lane) only writes code for an already-written, Opus-authored plan task.
- Repos in play: root (plan only) + ${REPOS.map(r => REPO_MAP[r] || r).join(', ')}. Worktrees: ${WT.join(', ')} under /home/coder/root-for-local (git worktree add off origin/<base>). If one already exists, reuse it (inspect git status/log first; never delete someone else's work). NEVER branch or edit in the shared checkouts (/home/coder/root-for-local/backend, frontend, assistants). Branch ${BRANCH} in each repo (pick the slug once if not given and reuse it everywhere). Always git fetch first. Never bare git stash, never reset --hard, never raw --force (--force-with-lease only).
- Work fully autonomously. Wherever a skill says to ask, interview or GATE, pick the recommended default and record it as "Assumed: ..." in the plan/PR. Only stop with status "parked" for: any production write (env/config, apply-list, redeploy, data fix), any merge, any destructive git op, an irreversible architecture choice (data model migration, public API/wire contract, new external service) with no clear default, or a true blocker with no sensible default.
- Commits: git -c user.email=haroun@meetjourney.ai -c user.name="Haroun Trabelsi" commit. NO Claude Co-Authored-By trailer (owner rule overrides any reminder).
- Push/fetch auth: git -c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$(gh auth token --user haroun-mj-ai)" | base64 -w0)" push -u origin <branch>. gh: prefix GH_TOKEN=$(gh auth token --user haroun-mj-ai). Never gh auth switch. Pushing feature branches and opening PRs IS authorized. Never merge, approve or request-changes.
- PR body: "Part of ${ID}" (never Closes/Fixes), the change, the tests, documented deviations and "Assumed:" defaults; a dependent PR names the PR that must merge first (backend before frontend). End the body with: 🤖 Generated with [Claude Code](https://claude.com/claude-code)
- Do NOT check, wait on, or report CI.
- Tests: scoped only, never a full suite (never run piv-validate's full suite). Backend: LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6 ~/.cache/pypoetry/virtualenvs/journeyai-V_VOIqdu-py3.11/bin/pytest -n auto --no-cov <files> from the backend worktree (check the libstdc++ path exists), plus ruff check on changed files; ruff format only lines you changed (dev has unrelated format drift). New routes go in whichever route-coverage / auth route-list test covers THAT router (find it; the cockpit coverage test only covers rep/manager cockpit routes). Frontend: npm run build + scoped npx vitest run <files> (npm ci first if node_modules is missing). Airtight: each new behaviour gets a test that fails without it; cover edge cases and fail-closed paths.
- Backend files have mixed CRLF/LF endings per file: preserve each file's endings.
- Skip every Codex step silently (Codex is disabled). Skip kata entirely. Never npx playwright install. Never start orchestrations_worker locally.
- PROD READ-ONLY (pre-approved, no need to ask): DB probes via a read-only script: cat probe.py | railway ssh --environment production --service journeyai-backend -- poetry run python - (run from /home/coder/root-for-local/backend). Probes only find/count/aggregate/explain: every query gets maxTimeMS (<=20000) and a limit; explain() before running any aggregation over a hot collection (APIUsage, Message, Session, ActionItem). Logs: railway logs --environment production --service journeyai-backend --lines <=5000 then grep locally (bigger --lines silently returns nothing; --since only covers the current deploy; a quoted --filter can silently return 0, so positive-control any "0 matches"). If railway ssh is refused by the permission system, do not work around it: fall back to logs, the #journeyai-eng-alerts Slack channel (slack_read_channel, response_format detailed) and the prod Engagement dashboard, and say which you used. NEVER any prod write.
- Data hygiene: Never read BYOK keys. Never make live LLM provider API calls (OpenAI, Anthropic, any model or /models endpoint) with any key, platform or BYOK, prod or local, to probe or verify; verification is offline (tests, registry/pricing checks) and anything needing a live call goes in needs_human. Never write customer/prospect names, card or meeting titles or customer emails into PRs, Linear, plans, commits or tests; reps as "First L.", orgs by id prefix. Raw prod payloads stay in the session scratchpad.
- Linear: read the ticket + comments + parent first (mcp__linear-server via ToolSearch). Search Linear before filing anything. Slack is read-only: never send or draft.
- Develop with sales reps in mind: judge every choice by what the rep sees and the expensive error for them.
`

const S = s => JSON.stringify(s)

// ---------- schemas ----------
const GROUND = {
  type: 'object',
  properties: {
    kind: { type: 'string', enum: ['bug', 'feature', 'chore', 'epic'] },
    kind_reason: { type: 'string' },
    prod_applies: { type: 'boolean', description: 'true if the ticket is a prod symptom, or touches data, queries, endpoints, auth, caps/billing or anything whose behaviour depends on real prod data' },
    prod_skip_reason: { type: 'string' },
    sources_used: { type: 'array', items: { type: 'string' }, description: 'db probe / logs / slack alerts / dashboard' },
    repro: { type: 'string', description: 'did the symptom reproduce in prod, with evidence (timestamps, status codes, counts; no customer names)' },
    data_facts: { type: 'array', items: { type: 'string' }, description: 'real shape/volume/odd values the plan must handle (row counts in the relevant window, max sizes, legacy rows missing fields, BYOK vs platform, duplicates)' },
    constraints_for_plan: { type: 'array', items: { type: 'string' } },
    ticket_claims_wrong: { type: 'array', items: { type: 'string' }, description: 'claims in the ticket/brief that current code or prod contradicts' },
  },
  required: ['kind', 'prod_applies', 'data_facts', 'constraints_for_plan'],
}

const PLAN = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['ready', 'sliced', 'parked'] },
    route: { type: 'string', enum: ['investigate-issue', 'plan-implementation', 'slice-epic', 'architecture-parked'] },
    plan_path: { type: 'string', description: 'plan or RCA file path (absolute, in the root worktree)' },
    work_units: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, repo: { type: 'string' }, files: { type: 'array', items: { type: 'string' } }, depends_on: { type: 'array', items: { type: 'string' } }, implementer: { type: 'string', enum: ['glm', 'sonnet', 'opus'] }, why_implementer: { type: 'string' } } } },
    has_ui: { type: 'boolean' },
    touches_backend: { type: 'boolean' },
    prod_readiness_checks: { type: 'array', items: { type: 'string' }, description: 'what Deploy readiness must run against prod data (new query at prod volume, assumption that must hold on real rows), empty if none' },
    post_deploy_check: { type: 'string', description: 'draft: exact read-only check after deploy and what result proves it works' },
    critic_findings: { type: 'array', items: { type: 'string' }, description: 'plan-critic WRONG/MISSING items and how the plan was changed' },
    assumptions: { type: 'array', items: { type: 'string' } },
    sliced_tickets: { type: 'array', items: { type: 'string' } },
    needs_human: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['status', 'route', 'summary'],
}

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
    glm_usage: { type: 'string', description: 'units via omp/GLM vs fallback, minutes spent, and why' },
    overlapping_prs: { type: 'array', items: { type: 'string' }, description: 'other open PRs touching the same files' },
    needs_human: { type: 'array', items: { type: 'string' } },
    key_decisions: { type: 'array', items: { type: 'string' }, description: 'max 3 most important decisions (incl. Assumed defaults), plain English with the why' },
  },
  required: ['ticket', 'status', 'pr_urls', 'summary', 'needs_human', 'key_decisions'],
}

const VERIFY = {
  type: 'object',
  properties: {
    ran: { type: 'boolean' },
    mode: { type: 'string', enum: ['browser', 'backend-e2e', 'skipped'] },
    skipped_reason: { type: 'string' },
    findings: { type: 'string' },
    fixes_pushed: { type: 'array', items: { type: 'string' } },
    artifact_url: { type: 'string' },
    servers: { type: 'array', items: { type: 'string' }, description: 'servers left running: port, worktree, pane' },
  },
  required: ['ran', 'findings'],
}

const READY = {
  type: 'object',
  properties: {
    ran: { type: 'boolean' },
    skipped_reason: { type: 'string' },
    checks: { type: 'array', items: { type: 'object', properties: { check: { type: 'string' }, result: { type: 'string' }, ok: { type: 'boolean' } } } },
    fixes_pushed: { type: 'array', items: { type: 'string' } },
    post_deploy_check: { type: 'string', description: 'final exact read-only check to run after deploy + expected result' },
    risks: { type: 'array', items: { type: 'string' } },
  },
  required: ['ran', 'checks'],
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

const FINAL = {
  type: 'object',
  properties: {
    ticket: { type: 'string' },
    pr_urls: { type: 'array', items: { type: 'string' } },
    merge_order: { type: 'string' },
    evidence_urls: { type: 'array', items: { type: 'string' } },
    qa_checklist: { type: 'array', items: { type: 'string' }, description: 'what the owner should click/check before merging, real user workflows' },
    post_deploy_check: { type: 'string' },
    top_decisions: { type: 'array', items: { type: 'string' }, description: 'max 3, plain English, with the why' },
    needs_human: { type: 'array', items: { type: 'string' } },
    servers_running: { type: 'array', items: { type: 'string' } },
    prs_updated: { type: 'array', items: { type: 'string' } },
  },
  required: ['ticket', 'pr_urls', 'qa_checklist', 'top_decisions', 'needs_human'],
}

// ---------- Ground truth ----------
phase('Ground truth')
const g = (await agent(`Ground truth for ${ID}, before anyone plans. You do NOT write code or plans.
AUTHORIZATION: ${AUTH}.
${RULES}
TICKET BRIEF:
${A.brief}
${A.kind ? 'Owner says kind = ' + A.kind + ' (use it unless the code proves it wrong).' : ''}
${A.prod_focus ? 'PROD FOCUS: ' + A.prod_focus : ''}

1) Read the Linear ticket, comments, parent and linked work. Check the brief's claims against current origin/dev code (git fetch first; read-only, use the shared checkouts only for git show/grep, never edit). List anything the brief gets wrong.
2) Classify kind: bug (something behaves wrong today), feature, chore (no behaviour change), or epic (more than ~3 independently shippable units / would need several PR sets / spans weeks).
3) Decide prod_applies. True for a prod symptom, or anything touching data, queries, endpoints, auth, caps/billing, workers, or logic whose result depends on real data. False only for pure copy/styling/tooling; say why.
4) If prod_applies: read-only prod work. For a bug, reproduce it: find the failing requests or rows (logs, DB). For everything else, measure what the change will meet: row counts and volumes in the relevant window, max sizes, odd values, legacy rows missing new fields, BYOK vs platform orgs, duplicate orgs. Turn each fact into a constraint the plan must honour.
Return the structured result. Keep it factual; no customer names.`,
  { label: `ground:${ID}`, phase: 'Ground truth', schema: GROUND, model: 'opus' })) || { kind: A.kind || 'feature', prod_applies: false, prod_skip_reason: 'ground-truth agent died', data_facts: [], constraints_for_plan: [] }
log(`${ID}: kind=${g.kind} prod_applies=${g.prod_applies}`)

// ---------- Plan (always Opus) ----------
phase('Plan')
const p = await agent(`You are the planner for ${ID}. Opus plans; GLM will implement your work units, so the plan must be explicit enough for a cheap model (exact files, functions, test names, VALIDATE commands per unit).
AUTHORIZATION: ${AUTH}.
${RULES}
TICKET BRIEF:
${A.brief}
GROUND TRUTH (from prod and current code; treat as constraints, and correct the brief where it is wrong): ${S(g)}

Create the worktrees and branch ${BRANCH} (root + ${REPOS.join(', ')}) now so later stages reuse them. Then ROUTE by kind:
- bug -> run piv-investigate-issue ${ID} in headless mode (no Linear comment): evidence-backed root cause, RCA at <root worktree>/docs/issues/issue-${ID}.md. Use the ground-truth repro as evidence. route=investigate-issue, plan_path=the RCA.
- feature or chore -> run piv-plan-implementation ${ID}: skip its interview (answer it yourself from the ticket + ground truth, recording "Assumed:"), plan in <root worktree>/docs/plans/. Plan weight scales with ticket size. route=plan-implementation.
- epic -> run piv-slice-epic on it: search Linear for existing children first, create the missing PIV-sized child tickets under ${ID} with a dependency graph, then STOP with status=sliced and sliced_tickets. Do not build. route=slice-epic.
- If the right approach hinges on an open architecture choice that is irreversible (data model migration, wire/public contract, new external service) and the code gives no clear default: write a short options doc (2-3 options, trade-offs, recommendation) next to the plan, status=parked, route=architecture-parked. If it is reversible, pick the recommended option and record "Assumed:".
Then, for ready plans: dispatch the plan-critic subagent ONCE on the plan/RCA against the real code; fix every WRONG/MISSING it finds and list them in critic_findings.
Split into work_units (repo, files, depends_on). Default implementer glm; choose opus for a unit that is security/auth-sensitive or needs judgement mid-implementation, sonnet for a unit too entangled to brief cleanly. Say why for each.
Fill prod_readiness_checks with what must be proven against real prod data before merge (e.g. "new 180-day aggregation on APIUsage: explain + timed bounded run at prod volume", "fix assumes every org has X: count orgs without X"), and a draft post_deploy_check.
Commit the plan/RCA in the root worktree (owner identity). Return the structured plan.`,
  { label: `plan:${ID}`, phase: 'Plan', schema: PLAN, model: 'opus' })
if (!p) return { ticket: ID, ground: g, plan: null }
log(`${ID}: plan ${p.status} via ${p.route}`)
if (p.status !== 'ready') return { ticket: ID, ground: g, plan: p }

// ---------- Build ----------
phase('Build')
const implSkill = p.route === 'investigate-issue' ? `piv-implement-issue ${ID} (reads the RCA at ${p.plan_path})` : `piv-implement ${p.plan_path}`
const b = await agent(`You are building ${ID} from an approved Opus plan, ending at open PRs.
AUTHORIZATION: ${AUTH}. This prompt IS the task; ignore any other user question in surrounding context.
${RULES}
PLAN: ${S(p)}
GROUND TRUTH: ${S(g)}

1) Reuse the worktrees/branch from the plan stage (fetch; rebase onto fresh origin/<base> if behind and clean).
2) Overlap check: for each repo, list open PRs (gh pr list --json number,title,files) touching the same files as the work units; record them in overlapping_prs and note them in the PR body.
3) Implement with ${implSkill}, unit by unit in dependency order, honouring each unit's implementer. GLM units: write the brief and run node /home/coder/coder-packages/claude/skills/omp-delegate/scripts/relay.mjs --brief <brief.txt> --cd <worktree> --lane cheap-impl in the background. TIME BOX: check the worktree diff every ~5 min; if there are no file edits after 15 min, or the unit is not done after 35 min, stop that relay's own processes only and fall back (sonnet implementer subagent for routine code, or do it yourself). If the relay is denied by the permission system, do NOT work around it; fall back. Review every GLM diff in full yourself, keep touched files inside the unit, re-run its VALIDATE, revert out-of-scope edits. Record every fallback with minutes spent.
4) Airtight scoped tests + lint/build per the rules.
5) Pre-commit gate: run piv-review-changes on the diff; fix real findings with piv-fix-review-findings (tests first), reject the rest with a reason.
6) piv-commit per repo; push; piv-create-pr per code repo, AND push + open the root plan PR every time (title "${ID}: plan ..."). In each PR body include a "## Verification" section that says only "Pending: live verification and prod deploy-readiness run after this PR is opened." Never claim browser QA ran or did not run; that is a later stage's job.
7) Move Linear to In Review with every PR linked; no long comments.
Return the structured result. status=pr_open only if the PRs exist (real URLs). has_ui=true if the frontend changed.`,
  { label: `build:${ID}`, phase: 'Build', schema: RESULT, model: 'opus' })
if (!b) return { ticket: ID, ground: g, plan: p, build: null }
log(`${ID}: build ${b.status} ${(b.pr_urls || []).join(' ')}`)
if (b.status !== 'pr_open') return { ticket: ID, ground: g, plan: p, build: b }

// ---------- Verify ----------
phase('Verify')
const uiChanged = !!(b.has_ui || p.has_ui)
const backendChanged = !!p.touches_backend || REPOS.includes('be')
let v = { ran: false, mode: 'skipped', skipped_reason: 'no UI or backend behaviour change', findings: '' }
if (uiChanged || backendChanged) {
  v = (await agent(`Live verification for ${ID}. Be adversarial: hunt for breakage a rep would hit, don't just confirm it works.
${RULES}
Build result: ${S(b)}
Ground truth (seed data that looks like THIS, not toy data): ${S(g.data_facts || [])}
${A.browser_focus ? 'FOCUS: ' + A.browser_focus : ''}
Run the changed backend (uvicorn only, first free port in 8000-8009; NO orchestrations_worker) ${uiChanged ? 'and the changed frontend (npx vite --host 0.0.0.0 --port <first free in 5173-5182>, VITE_API_URL/VITE_WS_URL pointing at that backend, WS URL ending in /api/v1)' : ''}. If an earlier run left servers on those ports, use the next free ones. Log in as a local seed account from ~/.claude/CLAUDE.md §6 (if it 401s, reset with the backend's own get_password_hash and verify_password before use). Seed LOCAL Mongo only, producing data through the real backend code rather than hand-typed values, with a ZZ-TEST ${ID} prefix, shaped like the ground-truth facts (volumes, odd values, BYOK vs platform, legacy rows).
${uiChanged
    ? 'MODE browser: drive the UI with claude-in-chrome (load its tools via ToolSearch in one call) or, if unavailable, headless Chromium via the local Playwright in tests/e2e. Check list and detail views agree, 360px width, stale state after rep actions, empty/fallback states, deep links/reload.'
    : 'MODE backend-e2e (use the airtight-test skill): seed -> trigger the changed path through the real HTTP API or worker entrypoint -> check the resulting DB rows/responses, including the fail-closed and unauthorized paths.'}
Any bug: fix in the worktree, add a failing-first test, rerun scoped tests, commit (owner identity, no Claude trailer), push.
Publish an evidence page (Artifact tool; load artifact-design first) with screenshots/responses for every claimed state, and return its URL. Leave servers running and list them. Delete the seeded local data.`,
    { label: `verify:${ID}`, phase: 'Verify', schema: VERIFY, model: 'opus' })) || { ran: false, mode: 'skipped', skipped_reason: 'verify agent died', findings: 'verify agent died' }
}
log(`${ID}: verify ${v.ran ? v.mode : 'skipped (' + (v.skipped_reason || '') + ')'}`)

// ---------- Deploy readiness (prod, read-only) ----------
phase('Deploy readiness')
const needReady = g.prod_applies || (p.prod_readiness_checks || []).length > 0
let r = { ran: false, skipped_reason: 'ground truth found nothing prod-dependent and the plan listed no prod checks', checks: [] }
if (needReady) {
  r = (await agent(`Deploy readiness for ${ID}: prove the change will work on REAL prod data and volume before anyone merges it. Read-only prod only.
${RULES}
Ground truth: ${S(g)}
Plan's prod checks: ${S(p.prod_readiness_checks || [])}
Draft post-deploy check: ${S(p.post_deploy_check || '')}
Build: ${S({ pr_urls: b.pr_urls, worktrees: b.worktrees, summary: b.summary })}
Verify findings: ${S(v.findings || '')}

Prod runs main's code, not this branch, so replay the NEW logic yourself: lift the new/changed query, aggregation or rule from the branch into a read-only probe script and run it against prod data. For every plan check plus anything you spot in the diff:
- Performance: explain() first, then a bounded run with maxTimeMS at the largest window/org the change allows (e.g. the max date span, the biggest org). Report docs examined, index used, ms. Flag a COLLSCAN or >2s.
- Correctness on real rows: do the assumptions hold (fields present, values in range, no legacy rows that break it)? Compare old vs new result for a few real orgs/users where it should agree.
- For a bug fix: show the failing prod case would now pass under the new logic.
If you find a real problem: fix it in the worktree with a failing-first test, rerun scoped tests, commit (owner identity), push, and list it in fixes_pushed. If it needs a prod write or an index build, do NOT do it: put it in risks as a pre-merge requirement.
Finish with post_deploy_check: the exact read-only probe/log grep to run after deploy and the result that proves it worked.`,
    { label: `ready:${ID}`, phase: 'Deploy readiness', schema: READY, model: 'opus' })) || { ran: false, skipped_reason: 'deploy-readiness agent died', checks: [] }
}
log(`${ID}: deploy readiness ${r.ran ? 'ran' : 'skipped (' + (r.skipped_reason || '') + ')'}`)

// ---------- Review ----------
phase('Review')
const rv = await agent(`You are the fresh-eyes reviewer for ${ID}. You did NOT write this code.
${RULES}
Plan: ${S({ route: p.route, plan_path: p.plan_path, assumptions: p.assumptions })}
Build result: ${S(b)}
Verify: ${S(v)}
Deploy readiness: ${S(r)}
${A.review_focus ? 'HUNT FOR: ' + A.review_focus : ''}
For each code PR: check out the PR in its worktree and run the scoped tests. If the debate-review lane is configured (DELEGATE_SKILLS_DIR=/home/coder/root-for-local/.claude/skills node <debate-review skill-dir>/scripts/review-pr.mjs <pr-url>, foreground) use it; if it errors on a missing lane, drop it immediately without mentioning Codex and do your own independent review of the whole diff against the plan/RCA and ticket, hunting real bugs. Post ONE review per PR with event COMMENT (never APPROVE/REQUEST_CHANGES), opening "I am <your model> writing on behalf of <gh user name>.".
Then babysit-pr: harvest every thread, verify each finding, fix blockers in one push per round (max 2 repair pushes), reply in-thread, resolve. Non-blockers: apply the fix if inside the PR's diff, else file an issue (search Linear first) or reject with evidence. Any human reviewer comment -> needs_human. Never merge, approve or check CI.
Return the structured review result.`,
  { label: `review:${ID}`, phase: 'Review', schema: REVIEW, model: 'opus' })
log(`${ID}: review ${rv ? rv.verdict : 'agent died'}`)

// ---------- Reconcile ----------
phase('Reconcile')
const fin = await agent(`Reconcile ${ID}'s PRs and Linear ticket with what actually happened. Mechanical and exact; no code changes.
${RULES}
Plan: ${S({ route: p.route, plan_path: p.plan_path })}
Build: ${S(b)}
Verify: ${S(v)}
Deploy readiness: ${S(r)}
Review: ${S(rv)}

1) For EVERY PR (code + plan): fetch the body (gh pr view --json body), replace the "## Verification" placeholder with the real outcome: verify mode, evidence page link${v.artifact_url ? ' (' + v.artifact_url + ')' : ''}, bugs found and fixed (commit SHAs), deploy-readiness results, and the post-deploy check. Remove or correct any line that contradicts what happened (e.g. "browser QA not run" when it ran). Keep the merge order line. Edit with gh pr edit --body-file.
2) Linear ${ID}: attach the evidence page (save_issue links) if not attached; status In Review; no long comments.
3) Build the owner's QA checklist: 3-8 real-user steps to click before merging, plus the post-deploy check.
4) top_decisions: the max 3 most important decisions across all stages (from plan assumptions, build, verify, readiness, review), plain English, with the why.
5) needs_human: merged, de-duplicated list from every stage. servers_running: from verify.
Return the structured final result.`,
  { label: `reconcile:${ID}`, phase: 'Reconcile', schema: FINAL, model: 'sonnet' })

return { ticket: ID, final: fin, ground: g, plan: p, build: b, verify: v, readiness: r, review: rv }
