---
name: worktree-create
description: Create one or more git worktrees for parallel development, each on its own branch with gitignored config copied in, dependencies installed, and a health check, by fanning out a setup subagent per worktree. Use when starting isolated parallel work, running several PIV loops at once, or when the user says "set up worktrees", "create a worktree", "spin up parallel branches", or invokes /worktree-create.
argument-hint: "[branch ...]  (one or more branch names; blank = ask)"
---

# Worktree Create

Stand up **any number** of isolated git worktrees from a list of branches — each created off the right base, given
its gitignored config, its dependencies, and a health check — by fanning out one setup subagent per worktree so
they run in parallel. The per-worktree work is app-agnostic and **detected from the repo**, never hardcoded.

## Input

`$ARGUMENTS` is the list of branches to create — **or**, for this project, a Linear ticket id plus which repos it
touches (see "Multi-repo mode" below); that's the common case here since root/`backend/`/`frontend/`/`assistants/`
are separate git repos, not packages in one.

- **None given** → ask which branches to create (or offer to derive them from the tickets in play). Don't guess.
- **One** → set up a single worktree inline (a fan-out of one is unnecessary).
- **Two or more** → fan out one subagent per branch, in parallel.

## Multi-repo mode (this project) — one worktree per repo, per ticket

When called with a Linear ticket id (e.g. from `piv-plan-implementation`'s "one worktree per parent ticket" step),
the fan-out axis is **repos, not branches** — every repo gets the *same* ticket, on its own branch, in its own
worktree:

- **Worktree naming**: `wt-eng<id>-<suffix>` at `<root-repo>/wt-eng<id>-<suffix>`, suffix `root`/`be`/`fe`/
  `assistants`/`obs`. Branch name: `haroun/eng-<id>-<slug>` in every repo (same slug, so cross-repo PRs are easy
  to spot later).
- **Base per repo, never one shared base**: root/`backend/`/`frontend/` → `origin/dev`; `assistants/`/
  `observability/` → `origin/main` (confirm with `git -C <repo> branch -a`, don't assume).
- **`--no-track` is mandatory**: `git -C <repo> worktree add --no-track wt-eng<id>-<suffix> -b haroun/eng-<id>-<slug> origin/dev`
  (or `origin/main`). Without `--no-track`, the branch's upstream becomes the base itself and a later bare
  `git push` targets `dev`/`main` directly.
- **Reuse before creating**: `git -C <repo> worktree list | grep "wt-eng<id>-"` first — a second run for the same
  ticket (a sub-issue, a re-plan) must reuse, never cut a second set.
- **Root worktree only — re-link personal skills.** This repo's `.claude/skills/*` are symlinks into
  `~/coder-packages/claude/skills/` kept out of git via `skip-worktree`, so `git worktree add` checks out the
  stale, git-tracked stub content instead — a fresh root worktree otherwise runs outdated skills. Immediately
  after creating a root worktree, recreate every top-level symlink from the main checkout:
  ```bash
  for link in <root-repo>/.claude/skills/*; do
    [ -L "$link" ] || continue
    ln -sfn "$(readlink -f "$link")" "<worktree>/.claude/skills/$(basename "$link")"
  done
  ```
- Which repos get a worktree: the ticket's own words, or a quick scout/grep pass if unclear. Default to
  root+`backend/`+`frontend/` unless the ticket clearly touches `assistants/`/`observability/` too, or is
  obviously narrower (single-repo).

Everything below (health check, deps install, gitignored config) still applies per repo — just substitute "repo"
for "branch" in the fan-out.

## Detect the project setup ONCE, before fanning out

Read `references/worktree-setup.md` — it is the general checklist of everything a fresh worktree needs plus how to
detect each piece. Determine from **this** repo (not from assumptions), one time:

- the **install command(s)** (monorepo → one per package),
- the **gitignored env/config files to copy** (or the repo's `.worktreeinclude`),
- the **verification/health-check command** (a health endpoint if the app exposes one, else a build/test smoke —
  prefer whatever CI runs),
- a **base port**, only if the health check starts a service.

Pick a worktree root (`worktrees/<branch>`, gitignored) and, if services get started, assign each worktree a
distinct port = `base + index` so parallel servers don't collide.

## Fan out one setup subagent per branch (parallel)

**Model: `Agent(subagent_type: "scout")` (haiku, low effort)** for every one of these dispatches — this is
mechanical, deterministic setup work (run an install command, copy files, hit a health check) with no design
judgment involved anywhere in it. Don't spend a bigger model's budget on it; the only place in this skill that
warrants more is deciding *which* repos/branches to set up in the first place, which happens one level up in
whichever skill called this one.

Spawn all subagents at once with the Task tool. Give every subagent the same prompt, substituting only `BRANCH`
and `PORT`:

```
Set up a git worktree for branch: BRANCH   (assigned port: PORT, only relevant if you start a service)

Follow the checklist in .claude/skills/worktree-create/references/worktree-setup.md. Concretely:
1. Create the worktree off the base branch:  git worktree add worktrees/BRANCH -b BRANCH
2. Copy the gitignored config/secrets the project needs into worktrees/BRANCH
   (the env/config files detected for this repo; verify each with `git check-ignore` before copying).
3. Install dependencies with the project's detected package manager (every package, for a monorepo).
4. Run any generate/build step the app needs to boot (skip if none).
5. Verify: run the detected health check (start + hit the health endpoint on PORT if there is one,
   else a build/typecheck/test smoke). Then stop any server you started.

Report exactly: worktree path · branch · deps installed (yes/no) · health check (PASS/FAIL) · any errors.
```

Fill the detected commands (install, env-file list, health check) into the template. For a single branch, run the
steps directly instead of spawning.

## Aggregate and report

Collect the reports and print a per-worktree summary (path · branch · deps · health · port), a combined
`N worktree(s) ready` line, the next step (open each worktree / start a PIV loop in it), and the cleanup reminder:
`git worktree remove worktrees/<branch>` once a branch is merged.

If any worktree failed its health check, surface it clearly and do **not** report it ready.

## Resources

- `references/worktree-setup.md` — the general, app-agnostic checklist of everything a fresh worktree needs, and
  how to detect each piece per project. Read it before detecting the setup.
