---
name: graphify
description: >-
  Query the prebuilt graphify code graphs of the JourneyAI backend and frontend (symbols, call/import
  edges, communities) to find entry points, callers, blast radius, and the path between two symbols
  before reading files. Use for "where is X handled", "what calls Y", "what breaks if I change Z",
  "how does A reach B" in backend/ or frontend/. Also covers rebuilding the graphs safely. Never run
  graphify's own full pipeline, `graphify install`, `graphify claude install`, or
  `graphify hook install` here.
---

# graphify (JourneyAI, personal setup)

Two code-only graphs, built by local tree-sitter parsing (no LLM, no network), stored outside the repos:

| graph    | file                                                   | size                      |
| -------- | ------------------------------------------------------ | ------------------------- |
| backend  | `~/.graphify/journey/backend/graphify-out/graph.json`  | ~71k nodes / 197k edges   |
| frontend | `~/.graphify/journey/frontend/graphify-out/graph.json` | ~10.6k nodes / 36k edges  |

They track the **primary checkouts** (`root-for-local/backend`, `root-for-local/frontend`) at their
last commit/checkout/merge. They do **not** reflect a linked `wt-*` worktree or uncommitted edits.
For a worktree branch, use the graph for orientation and confirm in the worktree's actual files.

## Querying: MCP first, CLI fallback

MCP servers `graphify-backend` / `graphify-frontend` (local scope, only in sessions launched from
`~/root-for-local`). Tools:

- `query_graph(question, token_budget)`: BFS from the best-matching symbols. **Always pass a
  budget** (start ~1500). Output warns `TRUNCATED` when it drops nodes. Narrow with
  `context_filter` (e.g. `["call"]`) or switch to `get_node` rather than just raising the budget.
- `get_node`, `get_neighbors`: precise lookups once you know the symbol label. These give the best
  signal-to-noise.
- `shortest_path(a, b)`: how one symbol reaches another (e.g. route handler → usage-cap check).
- `get_community`, `god_nodes`, `graph_stats`: area overview, hub symbols, sanity check.
- **Skip `list_prs` / `get_pr_impact` / `triage_prs`.** They call GitHub, and the active `gh`
  account lacks org access here.

CLI equivalent (when MCP isn't loaded, e.g. a session started in a worktree):

```bash
G=~/.graphify/journey/backend/graphify-out/graph.json
graphify query "usage cap exceeded" --graph $G --budget 1500
graphify explain "UsageCapExceeded" --graph $G
graphify path "usage_cap_exceeded_handler()" "UsageCapExceeded" --graph $G   # functions carry "()" in labels
graphify affected "UsageCapExceeded" --graph $G
```

## How to use the results

- Treat the graph as a **map, not the source of truth**. Use it to pick the 2–5 files worth
  reading, then read them. Never cite a graph edge as a fact without opening the code.
- BFS drifts into noise past depth 2 on the backend graph. The first ~15 nodes and their `src=`
  locations are the useful part.
- `INFERRED` edges (~10% backend) are heuristic. `EXTRACTED` edges come from parsing.
- Known blind spots: some backend files yield no symbols at all (seen with routers and account
  modules). If a query misses something you know exists, grep. Don't conclude it's absent.
  Dynamic dispatch, DI (`Depends`), ARQ job names as strings, and WebSocket message types are
  weakly linked.

## Keeping graphs fresh (automatic)

Git hooks (post-commit, post-checkout on branch switch, post-merge) in both repos call
`graphify-refresh`. It runs detached and returns instantly. It skips linked worktrees,
rebases/merges/cherry-picks, and `GRAPHIFY_SKIP_HOOK=1`. A trigger that lands while a rebuild is
running queues one rerun (max 3 passes). Typical cost: backend ~50s, frontend ~6–20s, incremental.

```bash
graphify-refresh --status                 # graph timestamps, running rebuilds, log tail
graphify-refresh --fg ~/root-for-local/backend   # manual foreground rebuild
tail -f ~/.cache/graphify-refresh.log
```

Where the hooks live (personal, not committed):
- frontend (and root/assistants/observability, which no-op): `root-for-local/scripts/hooks/`
  `post-commit` (appended block), `post-checkout`, `post-merge`.
- backend: Trunk's hooks dir `~/.cache/trunk/repos/e33567b0…/git-hooks/`. `post-commit` was
  added. `post-checkout`/`post-merge` are wrappers that call Trunk via
  `../git-hooks-orig/<hook>` symlinks (Trunk derives the hook name from `$0`), then
  graphify-refresh. Originals are kept as `*.trunk-orig`. A `trunk` reinstall may overwrite these.
  Re-add the marked `graphify-refresh-start/end` block if so.

## Safe-run rules (if building by hand)

graphify once hit **35 GB RSS** here, because nested `wt-*` worktrees (≈15 full backend copies)
were being parsed. So:

1. Code-only, always: `graphify extract . --code-only --out ~/.graphify/journey/<repo>`. Never the
   semantic/LLM pipeline from graphify's bundled skill (it fans out paid LLM subagents) unless the
   user asks for it explicitly.
2. Wrap it: `( ulimit -v 8000000; timeout 600 nice -n 10 graphify extract … )`.
3. Output goes outside the repo (`--out`). Never create `graphify-out/` inside a checkout.
4. First check nested worktrees are excluded:
   `git ls-files --others --exclude-standard --directory | grep '^wt-'` must print nothing.
   Otherwise add `/wt-*/` to `$(git rev-parse --git-path info/exclude)`. graphify-refresh enforces
   this check and refuses to run.
5. Don't run `graphify install`, `graphify claude install` (they edit global `~/.claude` / the
   committed CLAUDE.md and add a PreToolUse hook), `graphify hook install` (writes into the shared
   hooks dirs with in-repo output), or `graphify watch` (an unbounded background watcher).
6. Community labeling (`cluster-only`) auto-picks an LLM from whatever API keys are in env. Don't
   run it without asking.
