---
name: piv-plan-implementation
description: Creates a comprehensive, context-rich implementation plan through deep codebase analysis, a short clarifying interview, and external research. Accepts a tracker ticket (a Jira/Linear/GitHub key or URL, fetched from the tracker) or a free-form feature request. Use when you have a ticket or feature and need a one-pass-ready plan before writing any code.
argument-hint: "[ticket key/URL (fetched from your tracker), or a free-form feature description]"
---

# Plan a new task

## Feature: $ARGUMENTS

## Resolve the input first

`$ARGUMENTS` is either a **tracker ticket** (a key like `ACC-30`, a Linear id like `ENG-123`, or a Jira / Linear /
GitHub issue URL) or a **free-form feature description**. Tell them apart and handle each:

- **A Linear id or URL** (this project's tracker — the common case): `mcp__linear-server__get_issue` for the
  description and acceptance criteria, `mcp__linear-server__list_comments` for the discussion (requirements are
  often only in the comments, not the description). If the issue has a **parent issue**, that parent is the epic
  for "Inherit, don't re-decide" below — fetch it too and treat its architecture calls as already decided.
- **A Jira/GitHub ticket** (a key such as `ABC-123`, or an issue URL): **fetch it from the tracker before you plan**
  (Jira via the Atlassian MCP, GitHub via `gh issue view`). Read its summary, acceptance criteria, and per-ticket
  context. Then **follow its links up to the epic and the epic's linked architecture page** (Confluence via the
  Atlassian MCP) and inherit those decisions. Never plan from the bare key; the ticket body plus its epic and
  architecture are the real input.
- **A free-form description**: plan directly from it (greenfield or ad-hoc), asking clarifying questions as needed.

## Multi-repo worktree setup — one per parent Linear ticket

This project is 4 sibling repos (this root, `backend/`, `frontend/`, `assistants/`; `observability/` less often).
**Every new parent Linear ticket** (an issue with no parent of its own — top-level, not a sub-issue) gets its own
worktree in each repo it touches, created once, before any exploration:

1. **Sub-issue of an existing parent?** Reuse the parent's worktrees — don't create new ones. Find them:
   `git -C <repo> worktree list | grep "wt-eng<parent-id>-"` (naming convention below). Work inside those.
2. **New parent ticket, no worktrees yet for it?** Determine which repos are in play (the ticket's own words, or a
   quick `grep`/scout pass if unclear — default to root+`backend/`+`frontend/` unless the ticket is obviously
   scoped narrower or touches `assistants/`/`observability/` too). Invoke **`/worktree-create`** for exactly those
   repos, naming each worktree `wt-eng<id>-<suffix>` (`root`/`be`/`fe`/`assistants`/`obs`) with `--no-track`, off the
   right base per repo: **`dev`** for root/`backend/`/`frontend/`, **`main`** for `assistants/`/`observability/`
   (confirm with `git -C <repo> branch -a`, never assume).
3. Write and audit the plan **inside the root worktree** (`<root-worktree>/docs/plans/…` or `.claude/plans/…`,
   whichever this project uses), not the main checkout — so the plan commit rides into that ticket's own branch.

Skip this section entirely for a free-form/no-ticket plan with no tracker id — work in the main checkout as the
base template already assumes.

## Kata mirror — local step-ledger

This project layers a local step-ledger (`kata`) on top of Linear so a session dying mid-plan or mid-build is
recoverable without re-reading the whole ticket. Do this right after resolving a Linear ticket, before exploration
spends anything:

- `kata search "ENG-<id>" --agent` first — reuse an existing entry (e.g. from a prior `--feedback` re-plan) rather
  than duplicating.
- If none: `kata create "ENG-<id>: <title>" --body "<will hold the plan path once written>" --idempotency-key "ENG-<id>" --agent`.
- Either way: `kata meta set <ref> work.attention ok --agent`, and once the ticket's branch is known,
  `kata meta set <ref> work.branch haroun/eng-<id>-<slug> --agent`.
- A **blocking** open question surfaced during Phase 2's clarifying gate also gets
  `kata meta set <ref> work.attention needs-human --agent` plus a one-line `work.attention_msg` — clear it back to
  `ok` once answered.
- `kata` unavailable, or errors for any reason other than "no match" — note it and continue; best-effort tracking,
  never a reason to stop planning.

Skip entirely under a free-form/no-ticket plan (nothing to mirror without a Linear id).

## Mission

Transform a feature request into a **comprehensive implementation plan** through systematic codebase analysis, external research, and strategic planning.

**Core Principle**: We do NOT write code in this phase. Our goal is to create a context-rich implementation plan that enables one-pass implementation success for ai agents.

**Key Philosophy**: Context is King. The plan must contain ALL information needed for implementation - patterns, mandatory reading, documentation, validation commands - so the execution agent succeeds on the first attempt.

**Inherit, don't re-decide**: This is a **per-ticket** plan. If the ticket belongs to an epic that already has architecture decisions — a **linked architecture page** (e.g. a Confluence page from the `plan-architecture` skill, reached from the ticket's epic), an `## Architecture` / `## Engineering` section on the epic, or a local `architecture.md` / `engineering-plan.md` — **read it first** and treat its cross-cutting calls (stack & versions, data model, security boundaries, the seams new code plugs into) as **already decided**. Inherit them; don't reopen them. Plan only what's left at the ticket level: the specific files, the local patterns to mirror, the tests. If a ticket genuinely needs to break an epic-level decision, flag it in Open Questions rather than silently diverging.

## Planning Process

### Phase 1: Feature Understanding

**Deep Feature Analysis:**

- Extract the core problem being solved
- Identify user value and business impact
- Determine feature type: New Capability/Enhancement/Refactor/Bug Fix
- Assess complexity: Low/Medium/High
- Map affected systems and components

**Create User Story Format Or Refine If Story Was Provided By The User:**

```
As a <type of user>
I want to <action/goal>
So that <benefit/value>
```

### Phase 2: Codebase Intelligence Gathering

**Use specialized agents and parallel analysis — model-tiered, not one flat dispatch.** Cap at 3 dispatches, one
round, one message: don't spawn all 5 subsections as 5 separate agents. Group by what the work actually needs:

- **Mechanical lookup** ("where/how many/which files" — no judgment call) → `Agent(subagent_type: "scout")`
  (haiku, low effort). Covers most of **1. Project Structure**, **3. Dependency Analysis**, **4. Testing Patterns**.
- **Tracing/judgment** (follow a call path end-to-end, judge what's reusable vs. what should be new) →
  `Agent(subagent_type: "explorer")` (sonnet, medium effort). Covers **2. Pattern Recognition** and
  **5. Integration Points** — these need "what should be reused, not rewritten," which is a judgment call, not a
  lookup.
- You (the main session) still do the reading of *their reports* and the judging — subagents do the bulk file
  reading, never the design decisions.

**1. Project Structure Analysis**

- Detect primary language(s), frameworks, and runtime versions
- Map directory structure and architectural patterns
- Identify service/component boundaries and integration points
- Locate configuration files (pyproject.toml, package.json, etc.)
- Find environment setup and build processes

**2. Pattern Recognition** (Use specialized subagents when beneficial)

- Search for similar implementations in codebase
- Identify coding conventions:
  - Naming patterns (CamelCase, snake_case, kebab-case)
  - File organization and module structure
  - Error handling approaches
  - Logging patterns and standards
- Extract common patterns for the feature's domain
- Document anti-patterns to avoid
- Check CLAUDE.md for project-specific rules and conventions

**3. Dependency Analysis**

- Catalog external libraries relevant to feature
- Understand how libraries are integrated (check imports, configs)
- Find relevant documentation in docs/, ai_docs/, .claude/references or ai-wiki if available
- Note library versions and compatibility requirements

**4. Testing Patterns**

- Identify test framework and structure (pytest, jest, etc.)
- Find similar test examples for reference
- Understand test organization (unit vs integration)
- Note coverage requirements and testing standards

**5. Integration Points**

- Identify existing files that need updates
- Determine new files that need creation and their locations
- Map router/API registration patterns
- Understand database/model patterns if applicable
- Identify authentication/authorization patterns if relevant

**Clarify Ambiguities — GATE:**

Codebase analysis is done, so the open questions are now *specific*. This is the one moment where you know
enough to ask well and have not yet written anything. **GATE** means: post the questions, then stop. End the
turn and wait for the answers. Do not ask and answer in the same breath, and do not roll into Phase 3.

Ask in **one cluster**, numbered, 3-6 questions max, each carrying a **recommended default** so answering is
cheap ("I'll mirror the first unless you say otherwise"). Draw them only from what the analysis actually left
open:

1. **Scope boundary** — the adjacent thing a reasonable reader would assume is in scope. Confirm it is out.
2. **Pattern fork** — two existing patterns both fit. Name both with `file:line` and ask which to mirror.
3. **Contract shape** — the API surface, payload, or data-model change the ticket implies but never states.
4. **Failure behavior** — what happens on the error path the ticket is silent about.
5. **Preference** — a library or trade-off with no precedent in this codebase to inherit.
6. **Done** — an acceptance criterion that is missing, or written so that it cannot be checked.

Skip any category with nothing genuinely open; never manufacture questions to fill the list. If the ticket, its
epic and the architecture doc genuinely settle everything, say so in one line and proceed. Silence is not the
same as clearance.

**Thin answers:** reflect a vague answer back as the concrete choice it leaves open ("'handle errors gracefully'
— a 4xx with a message, or retry then 503?") and ask once more. Never upgrade a vague answer into a confident plan.

**If they decline** ("just write it"): honour it, but name what you are guessing. Every unanswered item becomes
an `Assumed — <the assumption>, confirm before execution` line in `OPEN QUESTIONS / ASSUMPTIONS`, and the task it
affects carries a `**GOTCHA**` naming it. Never guess silently.

**Already settled upstream:** anything the ticket, its epic, or the linked architecture page already answers is
not open. Inherit it and skip (see "Inherit, don't re-decide").

### Phase 3: External Research & Documentation

**Model: sonnet, medium effort** (a raw `Agent(model: "sonnet", effort: "medium")` call — no pinned type fits
"fetch and synthesize external docs," and haiku is too weak to tell a stale doc from a current one). Skip this
phase entirely for a well-understood internal-only change with no new library/API involved — it's not free.

**Documentation Gathering:**

- Research latest library versions and best practices
- Find official documentation with specific section anchors
- Locate implementation examples and tutorials
- Identify common gotchas and known issues
- Check for breaking changes and migration guides

**Technology Trends:**

- Research current best practices for the technology stack
- Find relevant blog posts, guides, or case studies
- Identify performance optimization patterns
- Document security considerations

**Compile Research References:**

```markdown
## Relevant Documentation

- [Library Official Docs](https://example.com/docs#section)
  - Specific feature implementation guide
  - Why: Needed for X functionality
- [Framework Guide](https://example.com/guide#integration)
  - Integration patterns section
  - Why: Shows how to connect components
```

### Phase 4: Deep Strategic Thinking

**Model: opus, high (max for a Heavy/high-complexity ticket) — regardless of what model the main session is
currently running as.** Phases 1-3 gathered evidence; this is the actual design reasoning the whole plan rests
on, and it's the one place in this pipeline worth paying for the top tier. There's no tool to switch the main
loop's own model mid-turn, so dispatch: `Agent(subagent_type: "Plan", model: "opus", effort: "high")`, fed
everything Phases 1-3 produced plus the risk/complexity assessment from Phase 1. The main session reviews and
presents what comes back — it does not draft the plan itself.

**Think Harder About:**

- How does this feature fit into the existing architecture?
- What are the critical dependencies and order of operations?
- What could go wrong? (Edge cases, race conditions, errors)
- How will this be tested comprehensively?
- What performance implications exist?
- Are there security considerations?
- How maintainable is this approach?

**Design Decisions:**

- Choose between alternative approaches with clear rationale
- Design for extensibility and future modifications
- Plan for backward compatibility if needed
- Consider scalability implications

### Phase 5: Plan Structure Generation

**Create comprehensive plan with the following structure:**

Whats below here is a template for you to fill for the implementation agent:

```markdown
# Feature: <feature-name>

The following plan should be complete, but its important that you validate documentation and codebase patterns and task sanity before you start implementing.

Pay special attention to naming of existing utils types and models. Import from the right files etc.

## Feature Description

<Detailed description of the feature, its purpose, and value to users>

## User Story

As a <type of user>
I want to <action/goal>
So that <benefit/value>

## Problem Statement

<Clearly define the specific problem or opportunity this feature addresses>

## Solution Statement

<Describe the proposed solution approach and how it solves the problem>

## Out of Scope / Non-Goals

<Explicitly bound the work: what this feature does NOT include. Name the things a reasonable reader might assume are in scope but aren't — this is what stops the agent from gold-plating or solving the wrong problem.>

- Not included: <thing> (defer to <later / separate ticket>)
- Not changing: <existing behavior to leave alone>

## Feature Metadata

**Feature Type**: [New Capability/Enhancement/Refactor/Bug Fix]
**Estimated Complexity**: [Low/Medium/High]
**Primary Systems Affected**: [List of main components/services]
**Dependencies**: [External libraries or services required]

## Related Work

<Links between this plan and the work around it. Distinct from CONTEXT REFERENCES below (which lists files/docs to read for *this* implementation) — this is the plan's place in the larger graph.>

**Implements**: <ticket id / link>   ·   **Epic**: <engineering-plan.md path or epic link — if this ticket inherits an epic's engineering plan (see Mission), record it here>

**Back-references** (plans this builds on or inherits decisions from):

- `.claude/plans/<prior-plan>.md` - Why: shares the auth seam / reuses the X service

**Forward-references** (plans that extend or supersede this — append as follow-ups get created):

- (none yet)

---

## CONTEXT REFERENCES

### Relevant Codebase Files IMPORTANT: YOU MUST READ THESE FILES BEFORE IMPLEMENTING!

<List files with line numbers and relevance>

- `path/to/file.py` (lines 15-45) - Why: Contains pattern for X that we'll mirror
- `path/to/model.py` (lines 100-120) - Why: Database model structure to follow
- `path/to/test.py` - Why: Test pattern example

### New Files to Create

- `path/to/new_service.py` - Service implementation for X functionality
- `path/to/new_model.py` - Data model for Y resource
- `tests/path/to/test_new_service.py` - Unit tests for new service

### Relevant Documentation YOU SHOULD READ THESE BEFORE IMPLEMENTING!

- [Documentation Link 1](https://example.com/doc1#section)
  - Specific section: Authentication setup
  - Why: Required for implementing secure endpoints
- [Documentation Link 2](https://example.com/doc2#integration)
  - Specific section: Database integration
  - Why: Shows proper async database patterns

### Patterns to Follow

<Specific patterns extracted from codebase - include actual code examples from the project>

**Naming Conventions:** (for example)

**Error Handling:** (for example)

**Logging Pattern:** (for example)

**Other Relevant Patterns:** (for example)

---

## IMPLEMENTATION PLAN

Phases run **top to bottom by default** — each assumes the phase above it is done. Where that is NOT the true dependency, make it explicit with a `**Depends on:**` line under the phase header, and a `**Independent of:**` line where two phases don't block each other. Independent phases are candidates to run in **parallel** (e.g. separate worktrees / parallel loops). Only annotate where it changes execution order or unlocks parallelism — skip the obvious sequential case.

### Phase 1: Foundation

<Describe foundational work needed before main implementation>

**Tasks:**

- Set up base structures (schemas, types, interfaces)
- Configure necessary dependencies
- Create foundational utilities or helpers

### Phase 2: Core Implementation

**Depends on:** Phase 1 (needs the base schemas/types)

<Describe the main implementation work>

**Tasks:**

- Implement core business logic
- Create service layer components
- Add API endpoints or interfaces
- Implement data models

### Phase 3: Integration

<Describe how feature integrates with existing functionality>

**Tasks:**

- Connect to existing routers/handlers
- Register new components
- Update configuration files
- Add middleware or interceptors if needed

### Phase 4: Testing & Validation

<Describe testing approach>

**Tasks:**

- Implement unit tests for each component
- Create integration tests for feature workflow
- Add edge case tests
- Validate against acceptance criteria

---

## STEP-BY-STEP TASKS

IMPORTANT: Execute every task in order, top to bottom. Each task is atomic and independently testable.

### Task Format Guidelines

Use information-dense keywords for clarity:

- **CREATE**: New files or components
- **UPDATE**: Modify existing files
- **ADD**: Insert new functionality into existing code
- **REMOVE**: Delete deprecated code
- **REFACTOR**: Restructure without changing behavior
- **MIRROR**: Copy pattern from elsewhere in codebase

### {ACTION} {target_file}

- **IMPLEMENT**: {Specific implementation detail}
- **PATTERN**: {Reference to existing pattern - file:line}
- **IMPORTS**: {Required imports and dependencies}
- **GOTCHA**: {Known issues or constraints to avoid}
- **VALIDATE**: `{executable validation command}`
- **SATISFIES**: {which acceptance criterion this task advances — e.g. AC #2 — so every task traces to a criterion}

<Continue with all tasks in dependency order...>

---

## TESTING STRATEGY

<Define testing approach based on project's test framework and patterns discovered during research>

### Unit Tests

<Scope and requirements based on project standards>

Design unit tests with fixtures and assertions following existing testing approaches

### Integration Tests

<Scope and requirements based on project standards>

### Edge Cases

<List specific edge cases that must be tested for this feature>

---

## VALIDATION COMMANDS

<Define validation commands based on project's tools discovered in Phase 2>

Execute every command to ensure zero regressions and 100% feature correctness.

### Level 1: Syntax & Style

<Project-specific linting and formatting commands>

### Level 2: Unit Tests

<Project-specific unit test commands>

### Level 3: Integration Tests

<Project-specific integration test commands>

### Level 4: Manual Validation

<Feature-specific manual testing steps - API calls, UI testing, etc.>

### Level 5: Additional Validation (Optional)

<MCP servers or additional CLI tools if available>

---

## ACCEPTANCE CRITERIA

<List specific, measurable criteria that must be met for completion>

- [ ] Feature implements all specified functionality
- [ ] All validation commands pass with zero errors
- [ ] Unit test coverage meets requirements (80%+)
- [ ] Integration tests verify end-to-end workflows
- [ ] Code follows project conventions and patterns
- [ ] No regressions in existing functionality
- [ ] Documentation is updated (if applicable)
- [ ] Performance meets requirements (if applicable)
- [ ] Security considerations addressed (if applicable)

---

## COMPLETION CHECKLIST

- [ ] All tasks completed in order
- [ ] Each task validation passed immediately
- [ ] All validation commands executed successfully
- [ ] Full test suite passes (unit + integration)
- [ ] No linting or type checking errors
- [ ] Manual testing confirms feature works
- [ ] Acceptance criteria all met
- [ ] Code reviewed for quality and maintainability

---

## OPEN QUESTIONS / ASSUMPTIONS

<Surface anything still uncertain instead of silently guessing. List the assumptions this plan makes, and any question that — if answered differently — would change the plan. Flag unresolved critical questions for the user before execution.>

## NOTES (open canvas)

<No fixed shape. Reason freely here: alternatives you weighed and rejected and why, a tradeoff matrix, a sequencing or rollout risk, a data-flow sketch, open threads, links — whatever serves the plan. The sections above template the plan's *shape* so the trifecta and the implementation agent can consume it; this section keeps your *reasoning* unconstrained. Prose, lists, tables, code blocks all welcome.>

## ADVERSARIAL REVIEW — red-team, guard-touching plans only

<Filled by Phase 5d. **Trigger**: fired / did not fire — <which guard class this plan changes, or
why none applies>. A did-not-fire record is mandatory: a missing section is indistinguishable from a
skipped step.

If fired: verdict (`ship` / `ship with the named additions` / `do not ship as specified`) ·
must-stay-fatal list with how each is preserved · discriminator attack · replay result (or "rows
unobtainable — recorded as a finding") · blast radius, enumerated call sites · already-solved check ·
what changed in the tasks above as a result.>

## PLAN AUDIT — independent model, before this plan is considered done

<Filled by Phase 5b below, run right after this plan is first drafted. Verdict: SOUND / SOUND WITH FIXES / DO NOT
IMPLEMENT. Per-claim VERIFIED/WRONG/MISSING against the real code, gaps found, what could not be checked. Keep
this honest even when the audit found nothing — it's the only record over time of whether this step earns its
cost. A DO NOT IMPLEMENT verdict means rework and re-audit once before this plan is handed off.>

## APPROACH COMPARISON — Codex's independent second draft (Medium/High complexity)

<Filled by Phase 5c below, skipped only for Low complexity — say "skipped, Low-complexity" rather than deleting
this section, so the skip is auditable too. Codex's proposal in a few lines, what it agreed
with, what (if anything) got grafted into this plan and why, what got rejected and why.>

## AMENDMENTS

<Append-only history of changes made to this plan AFTER it was first approved/executed. Leave empty at creation; newest entry at the bottom. Each entry: date — what changed and why.>

- <ISO date> — <what changed and why, e.g. "scope cut: deferred bulk-import to a follow-up ticket after AC review">
```

### Phase 5b: Independent audit — a fresh context that never saw the drafter's reasoning

**Model: `Agent(subagent_type: "plan-critic", model: "opus")`** (this project's `plan-critic` agent is pinned to
sonnet by default; the explicit `model` override here is deliberate — the audit needs Opus-tier reasoning. The
audit's independence comes from a fresh context with none of the Phase 4 drafter's rationale. Fable was used here
until 2026-09-23, when it was retired: Opus 5.5 outscores Fable 5.1 on FrontierCode, Terminal-Bench and the Vals
index at 40% of the price.) Give it the plan file, nothing else — it re-derives the claims by reading the actual repo, not by trusting
the plan's own reasoning. It returns per-claim `VERIFIED`/`WRONG`/`MISSING` labels, gaps the plan doesn't mention,
and an overall `SOUND` / `SOUND WITH FIXES` / `DO NOT IMPLEMENT` verdict.

Fold every finding into the plan, or record an explicit one-line reason it doesn't apply. Fill the plan's **PLAN
AUDIT** section with the verdict, what changed, and what was rejected and why. A `DO NOT IMPLEMENT` verdict means
rework and re-audit once before handing this plan off — never paper over it or proceed anyway.

This step specifically calls for a Claude sub-agent (`opus`), not Codex — Codex's own review commands
(`/codex:review`, `/codex:adversarial-review`) are deliberately gated to require a human typing them directly
(`disable-model-invocation: true` in their own definitions), so a skill's instructions can't invoke them
automatically, and cross-model research (arXiv:2607.21656) found Codex *reviewing* Claude-drafted work is the
harmful direction anyway — this step needs a claims-checker, and `/codex:adversarial-review` would just be Codex
grading Claude's plan, the pairing that doesn't pay off. If you want Codex's take on this plan too, run
`/codex:adversarial-review` yourself once the plan file exists — treat it as one more data point, not a verdict to
defer to. Phase 5c below is where Codex actually contributes, in the direction that does pay off.

### Phase 5c: Independent second draft — Codex, skip only for Low-complexity tickets

**Skip only when Phase 1 scored Estimated Complexity: Low** — a change small enough that a second design opinion
has nothing real to compare against. Run it for Medium and High alike: Codex's side of this is a flat
subscription, not metered spend, so the earlier "High-complexity only" bar (calibrated to Claude's judging cost,
not Codex's) was more conservative than it needed to be. Say the skip when it applies. The point isn't Codex
reviewing the opus-drafted plan (that's the harmful
direction); it's Codex **drafting its own independent approach from the same evidence**, blind to what Claude
proposed — the generative role the research shows is fine, paired with Claude doing the judging, which is the
direction that actually lifts quality:

Use `codex-delegate`'s `--read-only` mode, the `plan-debate` lane (`gpt-5.6-sol`, effort `max` — this project's
default for every Codex lane; `plan-debate` names the *job*, challenging a drafted plan, separately from
`review-debate`'s code-review job, even though they currently run the same model) — its own docs describe exactly
this recipe: a clean second opinion with no write risk.

```xml
<task>
Given this ticket: <ticket text>, and this codebase context: <Phase 1-3's findings — NOT the drafted plan>,
propose your own implementation approach: key design decisions, the files you'd touch, trade-offs, and risks.
This is a design proposal only — do not write or edit any code.
</task>
<grounding_rules>
Ground every claim in evidence from the codebase context given. Label anything that's an inference rather than
something you verified.
</grounding_rules>
<structured_output_contract>
Report: (1) your proposed approach, (2) key design decisions and why, (3) trade-offs and risks, (4) files you'd
touch.
</structured_output_contract>
```

```bash
node "<codex-delegate skill-dir>/scripts/relay.mjs" --brief brief.txt --cd <repo path> --lane plan-debate --read-only
```

`--read-only` means nothing to review/land — just read `result.json`'s `finalMessage`. Then **you** (not another
subagent — this is a judgment call, the main session's job) compare Codex's proposal
against the opus-drafted plan: same approach reached independently (strong corroboration, note it and move on),
a genuinely better idea in Codex's version (graft it into the plan, record what and why), or Codex's proposal is
weaker/misses something the opus draft already handles (say so, don't graft it just because a second model
produced it). Record the comparison in the plan's new **APPROACH COMPARISON** section below — including a
skipped Phase 5c (Low-complexity), so the skip itself is auditable.

### Phase 5d: Red-team the plan — ONLY when it touches a guard

**Conditional. Skip it and say so unless the trigger below fires** — an unconditional extra critic pass on
every ticket is the review-swarm this pipeline deliberately avoids, and it is not free.

**Trigger — fires when the plan changes the behaviour of any of** (verbatim from
`implement-issue/SKILL.md:360-365`): a verifier or postcondition, a validator, a dispatcher/entry gate, a cap
or budget check, a permission or entitlement check, a dedupe/idempotency key, a retry or fallback branch, or a
default that decides whether work happens at all. Classify from the plan's own `New Files to Create` /
`STEP-BY-STEP TASKS` file list and its `IMPLEMENTATION PLAN` phases; **when genuinely uncertain, run it.**

**Why this exists and Phase 5b does not cover it.** `plan-critic` asks *"are the plan's claims true?"*. That is
a different question from *"what does this change now let through?"*, and a plan can pass the first while
failing the second completely — the ENG-1406 case recorded at `implement-issue/SKILL.md:370-377`, where every
claim was independently verified and correct and the plan was still wrong. Phase 5c (Codex's second draft)
does not cover it either: Codex proposes an *alternative approach*, it does not attack the chosen one's blast
radius.

Dispatch a **fresh** `Agent` carrying `/red-team`'s rubric (model `opus`, effort matching Phase 1's
Estimated Complexity), given: the change stated as a behaviour delta (`/red-team` §0: *"after this change, X
will happen where Y happened before"*), the guard's current code and tests, and **explicitly not the plan's
own argument for why the change is right**. Require back the same five items `implement-issue`'s step 7b
requires: must-stay-fatal list, discriminator attack, replay, blast radius (enumerated call sites, not an
estimate), already-solved check.

Fold findings into the plan's new `## Adversarial review` section (next task), **including a recorded
non-firing trigger, so every skip is auditable**. Verdict routing: `do not ship as specified` → a
`DO NOT IMPLEMENT`-equivalent, rework before handing the plan off (headless mapping in the headless section).
`ship with the named additions` → fold the additions into the affected tasks and proceed.

**No `/challenge` step here, and state why in one sentence in the skill**: `/challenge` attacks the provenance
of a measurement an existing conclusion rests on — an instrument, a window, a population, a proxy. A
forward-looking implementation plan has no root-cause evidence chain of that shape; its factual claims are
`file:line` assertions about current code, which Phase 5b's `plan-critic` already re-derives against the real
repo, and its forward claims are exactly what `/red-team` attacks. Phase 1's bug fork has a `/challenge` step
because an RCA's 5-Whys chain genuinely can rest on a dashboard figure; a plan's cannot.

## Output Format

**Filename**: `.claude/plans/{kebab-case-descriptive-name}.md`

- Replace `{kebab-case-descriptive-name}` with short, descriptive feature name
- Examples: `add-user-authentication.md`, `implement-search-api.md`, `refactor-database-layer.md`

**Directory**: Create `.claude/plans/` if it doesn't exist

## Quality Criteria

### Context Completeness ✓

- [ ] All necessary patterns identified and documented
- [ ] External library usage documented with links
- [ ] Integration points clearly mapped
- [ ] Gotchas and anti-patterns captured
- [ ] Every task has executable validation command
- [ ] Phase 2's clarifying cluster was asked and answered, or explicitly recorded as nothing open

### Implementation Ready ✓

- [ ] Another developer could execute without additional context
- [ ] Tasks ordered by dependency (can execute top-to-bottom)
- [ ] Each task is atomic and independently testable
- [ ] Pattern references include specific file:line numbers

### Pattern Consistency ✓

- [ ] Tasks follow existing codebase conventions
- [ ] New patterns justified with clear rationale
- [ ] No reinvention of existing patterns or utils
- [ ] Testing approach matches project standards

### Information Density ✓

- [ ] No generic references (all specific and actionable)
- [ ] URLs include section anchors when applicable
- [ ] Task descriptions use codebase keywords
- [ ] Validation commands are non interactive executable

## Success Metrics

**One-Pass Implementation**: Execution agent can complete feature without additional research or clarification — clarification the *user* owes the plan belongs in Phase 2's gate, not deferred to the execution agent

**Validation Complete**: Every task has at least one working validation command

**Context Rich**: The Plan passes "No Prior Knowledge Test" - someone unfamiliar with codebase can implement using only Plan content

**Confidence Score**: #/10 that execution will succeed on first attempt

## Report

After creating the Plan, provide:

- Summary of feature and approach
- Full path to created Plan file
- Complexity assessment
- Key implementation risks or considerations
- Estimated confidence score for one-pass success
- Phase 5b's audit verdict (`SOUND` / `SOUND WITH FIXES` / `DO NOT IMPLEMENT`) and what it found
- Phase 5c's outcome if it ran (Medium/High complexity) — corroborated, or what got grafted from Codex's approach
- Phase 5d's outcome — whether the red-team trigger fired, and if so the verdict (`ship` / `ship with the named
  additions` / `do not ship as specified`) and what it found; if it did not fire, say so
- If a Linear ticket was resolved: the kata ref from the mirror step above, and update it now that the plan path
  is known — `kata comment <ref> --message "plan: <path>" --agent` (or fold the path into the ticket body if the
  ref was just created and has no comment yet).

## Headless mode (--headless)

Read `.claude/skills/headless-protocol.md` first — the `status.json` shape, the local queue contract, the
ask→fallback rule, the Linear footprint are defined once there. This section states only what this skill's own
ask points map to.

**Phase**: `design` (or `redesign` when `--feedback` is present). `phase_at_question: "design"` on every
`NEEDS_HUMAN`. Invoked as `/piv-plan-implementation ENG-<id> --headless [--feedback '<text>'] --run-dir <d>`.

**Input is always an existing Linear issue id.** The free-form-description branch of `## Resolve the input
first` is interactive-only. A headless invocation whose argument does not match `ENG-\d+`, or whose Linear
fetch returns nothing, is `FAILED` with `detail` naming what was passed — never a plan drafted from a bare id.

**The worktree + branch sections are mandatory, not optional.** `## Multi-repo worktree setup` (`:27-45`) and
`## Kata mirror` (`:47-64`) each end with a "skip entirely for a free-form/no-ticket plan" escape; **that
escape never applies headlessly**, because headless input is always a Linear id. Run both unconditionally,
`--feedback` re-runs included (both are harmless no-ops when repeated). This section is materially lighter
than Phase 1's equivalent for `piv-investigate-issue` for one reason worth stating: that skill had **no**
branch discipline at all and the mandate had to be invented; this one already has the right one —
`wt-eng<id>-<suffix>` worktrees off the right base per repo (`dev` for root/`backend/`/`frontend/`, `main` for
`assistants/`/`observability/`, confirmed per repo, never assumed), plan written *inside* the root worktree,
and `work.branch haroun/eng-<id>-<slug>` recorded at `:57`. Headless only removes the opt-out and adds the
branch cut: create/checkout **`haroun/eng-<id>-<slug>`** in the root worktree before writing anything, so the
plan commit is on the branch the build act will reuse and rides into that branch's PR — the skill's own
`piv-implement:22-24` warning ("a plan committed on the base branch won't be in this branch's PR") is the
reason.

**Never work in the main checkout**, for Phase 1's three verified reasons, unchanged: it is permanently dirty
and on an unrelated branch, so every downstream dirty-tree and branch heuristic misfires; `AP_BUILD_SLOTS > 1`
means two acts must never share a checkout; and the `dontAsk` profile only permits
`git push -u origin haroun/*`.

**Linear claim + kata mirror, first thing**: claim (`assignee: me`, `state: In Progress`) via
`mcp__linear-server__save_issue`, then `:47-64`'s `kata search "ENG-<id>" --agent` / create with
`--idempotency-key`, `kata meta set <ref> work.attention ok`, and `work.branch haroun/eng-<id>-<slug>` once the
branch is cut. This is the only place a feature ticket's Linear claim can happen — `ap-decide.py` has no
Linear credential. Mirrors Phase 1's `piv-investigate-issue` pattern exactly, including which kata calls
happen where.

**Ask-point mapping table:**

| ask point | headless resolution | recorded as |
|---|---|---|
| **Phase 2's clarifying GATE** (`:152-178`) — "post the questions, then stop. End the turn and wait" | **The skill already has a documented headless-safe fallback and it is used verbatim** (`:176-178`): nobody answers, which is the `If they decline` branch — honour it, and **name every guess**. Each unanswered item becomes an `Assumed — <the assumption>, confirm before execution` line in the plan's `OPEN QUESTIONS / ASSUMPTIONS`, and each affected task carries a `**GOTCHA**` naming it. Never guess silently, and never ask-and-answer in the same breath as if a human had replied. **Not a `NEEDS_HUMAN`** — see the note below the table. **Also override the skill's own interactive kata rule for this specific gate**: `:58-60` sets `kata meta set <ref> work.attention needs-human` for a blocking Phase-2 question, but headless never parks here — keep `work.attention ok` throughout, since the assumptions proceed straight into the plan rather than stopping the act. Applying the interactive kata rule unmodified would leave the ticket's kata signal falsely stuck at `needs-human` while the act itself carries on normally to `piv-draft-review`. | the plan's own `OPEN QUESTIONS / ASSUMPTIONS` section, which becomes the review agenda at `piv-draft-review` |
| Thin/vague answer handling (`:173-174`) | unreachable headlessly (no answers arrive at all) — the decline branch above covers the whole gate | n/a |
| Ticket, epic and architecture genuinely settle everything (`:169-171`) | already headless-shaped: say so in one line in the plan and proceed | the plan's one-line statement |
| Phase 3 external research (`:183-206`) unavailable — `WebSearch` denied or a fetch fails | documented default: **note the gap in the plan and continue**, never stall. Same shape as Phase 1's Codex-denial rule. `WebSearch` is added to the allow list by this plan's permissions task; treat a denial as evidence the profile drifted, not as a failure | `detail` + a line in the plan's `Relevant Documentation` |
| **Phase 5b `plan-critic` returns `DO NOT IMPLEMENT`** (`:537-539`) | the skill's own default: **rework once and re-audit**. If the second audit is still `DO NOT IMPLEMENT` → **`NEEDS_HUMAN`**. Never paper over it, never proceed anyway | `question` = the verdict plus the single most load-bearing finding; the full audit lives in the plan's `PLAN AUDIT`; kata `work.attention needs-human` |
| Phase 5c Codex second draft fails / `codex_unavailable` / denied (`:550-592`) | documented default: note it in `APPROACH COMPARISON` ("second draft unavailable — <reason>") and proceed. A bonus check, not a gate — same as Phase 1's treatment of the investigate act's Codex corroboration | `APPROACH COMPARISON` + `detail` |
| **Phase 5d red-team `do not ship as specified`** | **`NEEDS_HUMAN`** — never a silent override, exactly as Phase 1 maps `piv-investigate-issue`'s step-7 verdicts | `question` = the verdict plus the must-stay-fatal case the plan does not preserve; findings live in `ADVERSARIAL REVIEW`; kata `needs-human` |
| `/worktree-create` fails, or the base branch cannot be confirmed for a repo | `FAILED`, `detail` = the failing command and its stderr. The remedy is git work at a terminal, which the `ap reply` channel cannot express | `detail` |
| Linear ticket has an empty body **and** no comments **and** no parent epic | `FAILED`, `detail: "nothing to plan from"`. This is the one line between "proceed with `Assumed —` lines" and "draft a guess pyramid": *some* information → proceed; *zero* → fail fast | `detail` |

**Does a `piv-plan-implementation` run ever legitimately reach `NEEDS_HUMAN`? Yes — but never from the
clarifying gate.** State this explicitly, because it is the question a reader will arrive with. Exactly two
park points exist: a twice-`DO NOT IMPLEMENT` audit, and a `do not ship as specified` red-team verdict. Both
are *a critic on a different model lineage saying this plan should not be built*, which is precisely the class
of judgment a human owns.

The clarifying gate is **not** one of them, and the reason is structural rather than a preference: the
questions the skill would have asked interactively do not disappear — they become `Assumed —` lines in the
plan's own `OPEN QUESTIONS / ASSUMPTIONS` section, and that plan then goes to `piv-draft-review`, where a human
reads it and can `ap approve` or `ap reply '<answers>'` before **a single line of code is written**. The
approval gate *is* the clarifying interview, deferred by one hop and made asynchronous. Parking at the gate
instead would spend a `needs-input` park to ask the same questions the approval gate is about to surface
anyway, and would cost a whole re-dispatch to resume. State the one condition this rests on: **it is safe only
because the `piv-draft-review` gate exists.** If a future change ever auto-approves plans by default, this
mapping must be revisited.

**Phase 5b and 5c run headlessly, unchanged.** Both are read-only sub-agent dispatches with no human ask point
of their own — 5b is an `Agent(subagent_type: "plan-critic", model: "opus")` call; 5c is
`node "<codex-delegate skill-dir>/scripts/relay.mjs" --brief brief.txt --cd <repo> --lane plan-debate
--read-only`, which writes nothing. Keep the `opus` model override and the fresh context on 5b (an audit
that sees the drafter's rationale ends up agreeing with it) and keep 5c's read-only mode. Two headless-specific rules: **(a)** run 5c as
a **blocking foreground** command despite `codex-delegate`'s usual background advice — backgrounding across a
turn boundary is fatal under the protocol's never-background rule, and 5c at `effort: max` can run 10-20
minutes; **(b)** `Bash(node *)` is required and is added by Phase 1's permissions task — a denial means
"second draft unavailable", not a failure.

**Plan output path — headless overrides `## Output Format`.** `.claude/plans/{kebab-case-name}.md`
(`:594-601`) is interactive-only. Headless writes **`docs/plans/<ENG-ID>-<slug>.md`** in the root worktree,
e.g. `docs/plans/ENG-1400-insights-date-filter.md`. Four reasons, all verifiable, and worth stating in the
skill because each is a trap:

- **`.claude/plans/` is untracked in the work repo** (verified: `git status --porcelain .claude` prints
  `?? .claude/plans/`). Writing there creates exactly the dirty-tree condition `piv-create-pr`'s "Uncommitted
  changes → STOP" precondition fires on, two phases later. This is the same trap Phase 1 found for
  `.claude/reports/` and solved the same way.
- **The plan must be committed anyway.** The build act is a different session, potentially hours later, in a
  different process; it reads the plan from disk. An uncommitted plan is unreadable to it and leaves the
  design act's worktree dirty.
- **`docs/plans/` is this repo's real convention and is tracked** (verified: ~60 committed files, and it is
  where both this plan and Phase 1 live). It therefore exists in every fresh worktree, needing no `mkdir`.
- **ENG-id-anchored-at-position-zero makes it deterministically resolvable**, which is what `ap-decide.py`'s
  new resolver needs and what keeps it out of `resolve_plan_path`'s substring hazard.

Note the deliberate divergence: the directory's existing files are date-prefixed (`YYYY-MM-DD-<slug>.md`).
Headless plans are **not**, so that (a) a resolver can anchor on `^<ENG-ID>-` with a trailing hyphen — which is
what makes `ENG-123` not match `ENG-1234-foo.md` — and (b) a piv plan is distinguishable from a legacy
`implement-issue` plan for the same ticket by filename shape alone, which matters during the coexistence
window. Interactive runs keep `.claude/plans/`; nothing about the interactive contract changes.

**Commit the plan before the queue write**, on the ticket's branch in the root worktree. Same discipline the
legacy plan phase already has (`implement-issue/SKILL.md:1202-1204`) and Phase 1's investigate act mirrors.

**End state**: after the commit, one write —

```bash
python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state piv-draft-review \
  --field artifact_path=/absolute/path/to/docs/plans/<ENG-ID>-<slug>.md \
  --event "plan ready for review"
```

then `status.json` with `status: DONE`, `phase: "design"`, `artifact_path` = the plan path, `detail` = the
Phase 5b verdict + whether 5c ran + whether 5d fired + the confidence score. Carry Phase 1's emphatic warning
verbatim in shape: **without this write the ticket never leaves `piv-drafting` and the pipeline stalls after
every plan** — do not skip it, and do not reorder it before the commit lands.

**`--feedback '<text>'`**: treat as the human's answers to the plan's `OPEN QUESTIONS / ASSUMPTIONS` and/or a
change of direction — not a mechanical correction. Revise the plan **in place** (same file, same branch, a new
commit), convert every now-answered `Assumed —` line into a settled decision, and **re-run Phase 5d's trigger
against the revision** — a revised approach can newly touch a guard. Re-run 5b if the revision changed any
task's file list. Then re-record `artifact_path` and write `DONE` as above. Phase is `redesign`.

- **PATTERN**: `implement-issue/SKILL.md:1160-1231` (`--phase plan`) — structurally a template: input rule,
  claim + kata, ask table, artifact commit, end-state write, `--feedback` handling. And Phase 1's
  `piv-investigate-issue` headless section for how that template was already adapted into a `piv-*` skill.
- **GOTCHA**: `$ARGUMENTS` under a slash invocation is the **whole** argument string
  (`ENG-1400 --headless --run-dir /x`), not just the ticket id. The `## Resolve the input first` section must
  extract the `ENG-\d+` token rather than treating `$ARGUMENTS` as one opaque input. Same hazard
  `piv-implement`'s `--plan` has.
- **GOTCHA**: Phase 4 dispatches `Agent(subagent_type: "Plan", model: "opus", effort: "high")` and the act's
  own pinned model is `opus` — the sub-agent dispatch is unaffected by the act's model pin and stays as
  written.
- **GOTCHA**: The act runs on the **plan lane with no ports**. This skill starts no dev servers and must not;
  if a future revision adds one, it needs the `--ports` treatment `piv-implement` gets, and the plan lane has
  no port pair to give it.
- **GOTCHA**: `mcp__linear-server__save_comment` is not on the allow list — this skill's `## Report` step
  suggests a kata comment, which is fine (`Bash(kata *)` is allowed), but **never** a Linear comment. Phase 1's
  Linear-footprint rule applies unchanged.
