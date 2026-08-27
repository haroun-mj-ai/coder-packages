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

### Phase 5b: Independent audit — a genuinely different model family from the drafter

**Model: `Agent(subagent_type: "plan-critic", model: "fable")`** (this project's `plan-critic` agent is pinned to
sonnet by default; the explicit `model` override here is deliberate — `fable` is a different reasoning lineage
from the opus that drafted the plan in Phase 4, which is the entire point of this step. Skipping the override and
running the audit on the same family that drafted the plan defeats it — a model rarely catches its own blind
spots.) Give it the plan file, nothing else — it re-derives the claims by reading the actual repo, not by trusting
the plan's own reasoning. It returns per-claim `VERIFIED`/`WRONG`/`MISSING` labels, gaps the plan doesn't mention,
and an overall `SOUND` / `SOUND WITH FIXES` / `DO NOT IMPLEMENT` verdict.

Fold every finding into the plan, or record an explicit one-line reason it doesn't apply. Fill the plan's **PLAN
AUDIT** section with the verdict, what changed, and what was rejected and why. A `DO NOT IMPLEMENT` verdict means
rework and re-audit once before handing this plan off — never paper over it or proceed anyway.

This step specifically calls for Claude's own cross-model tier (`fable`), not Codex — Codex's own review commands
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

Use `codex-delegate`'s `--read-only` mode (the `review-debate` lane already configured) — its own docs describe
exactly this recipe: a clean second opinion with no write risk.

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
node "<codex-delegate skill-dir>/scripts/relay.mjs" --brief brief.txt --cd <repo path> --lane review-debate --read-only
```

`--read-only` means nothing to review/land — just read `result.json`'s `finalMessage`. Then **you** (not another
subagent — this is a judgment call, the main session's job) compare Codex's proposal
against the opus-drafted plan: same approach reached independently (strong corroboration, note it and move on),
a genuinely better idea in Codex's version (graft it into the plan, record what and why), or Codex's proposal is
weaker/misses something the opus draft already handles (say so, don't graft it just because a second model
produced it). Record the comparison in the plan's new **APPROACH COMPARISON** section below — including a
skipped Phase 5c (Low-complexity), so the skip itself is auditable.

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
- If a Linear ticket was resolved: the kata ref from the mirror step above, and update it now that the plan path
  is known — `kata comment <ref> --message "plan: <path>" --agent` (or fold the path into the ticket body if the
  ref was just created and has no comment yet).
