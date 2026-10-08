---
name: standup-update
description: Turn recent work into a spoken script for "hey Haroun, what are your updates?" — concise, goal-oriented, non-technical, each point told as "I noticed X behaves like Y, so I changed it, and now it does Z", ending with what's next, the health number, and questions for Ryan (PM). Also pulls live read-only production numbers (spend by org/rep/agent, who's active or dropped off, cap headroom, transcripts vs follow-ups, cleanup counts, failures) so the doc answers Ryan's ops questions before he asks. Covers yesterday by default or an explicit date range, gathers from Linear AND GitHub, and puts every workstream in one doc. Publishes it to a secret GitHub gist (updating the existing one). Use when asked for a standup update, a status script, "what do I say", or to refresh the update gist. Do NOT use for a technical write-up, a PR description, or a Linear comment.
---

# standup-update

Produce what Haroun will literally **say out loud** when someone asks for his
updates. It is a script, not a report: short sentences, first person, spoken
rhythm, and no jargon a manager or a sales lead wouldn't use.

## 0. Window and workstreams

- **Window:** **yesterday** by default (00:00 yesterday → now, local time).
  An explicit range in the request wins: "since Friday", "Friday to now",
  "this week", or two dates. Resolve it to absolute dates and print the
  window in the doc's subtitle, e.g. "Fri 2 Oct → Tue 6 Oct 2026".
- **Workstreams:** take every one the request names (e.g. "P4 and D2").
  If none is named, use the parent tickets that Haroun's activity in the
  window rolls up to. **Every workstream goes in ONE doc**, with one
  section each. Put work that fits no workstream in a short "Also this
  week" section, or drop it if it's trivial.

## 1. Gather (cheap, factual, both sources)

Collect only what's needed, for the window only:

- **Linear:** `list_issues` with `assignee: me`, `updatedAt: <window start>`, and fields `id,title,status,parentId,completedAt`. Group by `parentId` into workstreams. Also read the parent ticket of each workstream for its goal and health metric.
- **GitHub:** Haroun's PRs in the window, across `journeyai-backend`, `frontend`, `assistants` and `journey`, using the haroun-mj-ai token:
  `gh pr list -R JourneyAI-Team/<repo> --author haroun-mj-ai --state all --search "updated:>=<window start>" --json number,title,state,mergedAt,headRefName`
  Map each PR to its ticket through the ENG id in its title or branch.
- **Live or not:** a PR is **live** only if its merge commit is an ancestor of `origin/main` (`git merge-base --is-ancestor <sha> origin/main`, after fetching with the token header). Bucket the work like this:
  - **merged to dev but not on main:** "merged, ships with the next release";
  - **open PR:** "in review";
  - **Todo or Backlog:** "next".

  A Done or Staging ticket is not proof that the change is live.
- **Health metric:** use the workstream's own number. That can come from an artifact, the previous gist, the parent ticket or, for P4, today's `~/.p4-nightly-check/reports/<date>.md`. Keep the shape **before → live today → once the rest ships**. Never invent a number. A replay estimate must be called an estimate. A live reading that contradicts an earlier claim must be said plainly.
- **Surprises:** anything that overturned an earlier claim, including one made in the previous version of this gist.

## 1b. Live ops numbers from prod (always)

Ryan asked Haroun to own **usage and cost operations** and to come to
every meeting able to answer, with real numbers:

- what's spending money (which agents, which reps)
- who's using the platform and what they use
- who dropped off
- who's spending a lot or running out of money
- which features are used most
- whether anything external broke (e.g. the search provider running out of credit)
- for D2, transcripts in vs meeting follow-ups out, with examples of misses
- for P4, how many cards the cleanup closed and kept

Answer all of these, plus any similar question the window raises, from
**live production data**, never from memory or an older gist.

- Run the bundled read-only probe (prod reads are pre-approved; it refuses
  to run anywhere but production):
  `cat <skill dir>/scripts/ops_pulse.py | railway ssh --environment production --service journeyai-backend -- poetry run python - --days <window days>`
  from the backend checkout. Use the window from section 0. For a
  weekend-spanning window, pass the real span (e.g. `--days 3`). The 7-day
  activity comparison is fixed.
- It prints seven blocks: spend, activity, cap headroom, agent usage,
  transcripts vs follow-ups (with up to 8 misses), cleanup and queue size,
  and failures. It excludes [SEED]/test orgs and Journey staff.
- **Similar questions it doesn't cover** (e.g. "how much did one org spend
  this month?", "which rep never opened Journey?"): write a one-off
  read-only aggregate in the same style. Stick to find/aggregate/count only,
  assert `RAILWAY_ENVIRONMENT_NAME == "production"` and pipe it on stdin.
  If it's a question Ryan will ask again, add it to the probe.
- **Never** write to prod. Never upload a file into the container. If the
  classifier blocks the probe, say so and print the command for Haroun to
  run with `! …`. Don't route around it.
- **Read the numbers like a skeptic before you say them:**
  - Spend is on a named axis: platform vs BYOK. BYOK is the customer's own
    key and isn't Journey's cost.
  - Agent run cost is an estimate. The billing ledger is the per-call cost.
  - Activity is a lower bound.
  - Cap headroom is an approximation. Confirm anything near a cap on the
    Engagement dashboard.
  - An odd number (e.g. a rep with ~300 live cards) is a finding to raise,
    not a typo to smooth over.
- **Customer data:** the doc may carry counts, names, org names and call
  subjects. It must never carry transcript or email content. Never send any
  of this to a non-Claude model.

## 2. Write the script (this exact shape)

```markdown
# "Hey Haroun, what are your updates?"
*<workstreams>, <window>. As of <date>.*

## The 20-second version
> <one or two lines per workstream: goal, where it started, where it is, where it'll be>.

---

# <Workstream 1, plain name>

## If they want more, one at a time
**1. <plain-English name>: <live | merged, ships next release | in review | next>**
> I noticed <what the rep/customer experienced>. I changed it so <behaviour>. Now <outcome>.
… (one block per meaningful piece of work in the window; merge tiny tickets into one point)

## What's next
> - **<label>:** <one line>.

## Where that leaves the health number
> So, in terms of health: <metric in plain words>
> - was **X%** before I started,
> - is **about Y%** with what's live today (<a out of n>),
> - and should reach **about Z%** once the rest ships (<b out of n>).
>
> <one honest caveat>

## If someone asks "any surprises?"
> <one line>

---

# <Workstream 2> … same four sections …

---

# The numbers (live from production, <window>)
*Pulled <timestamp>. Read-only. Platform = Journey pays; BYOK = the customer's own key.*

## What's spending money
> - **Total:** $X platform + $Y on customers' own keys. **Biggest org:** <org> ($…).
> - **Top reps:** <name, $…>, …
> - **Top agents:** <plain name, $…>, …

## Who's using it, who dropped off
> - <org>: N reps active this week (was M). New or back: … Dropped off: …

## Anyone running out of money?
> <nobody near a cap | name at X% of their monthly cap>

## Meeting follow-ups: calls in vs follow-ups out
> <org>: N of M customer calls got follow-ups. <Misses: one line each, or "none missed">.

## Nightly cleanup
> <org>: closed N, kept M. Biggest live queue: <rep>, N cards (median N).

## Anything break?
> <failures in plain words, or "nothing customer-facing; search provider healthy">

---

# Questions for Ryan
*Ryan is the PM. He knows sales and how reps actually think and work better than I do.*

**<Workstream>**
1. <question> *(why I'm asking: <what I'd build differently depending on the answer>)*
…
```

The numbers section is spoken like the rest: plain agent names ("the email
reader" for email intelligence, "outreach drafting" for prospecting outreach),
rounded dollars, and one sentence on anything surprising.

The order inside each workstream is fixed: the points, then what's next,
**then** the health number (Haroun's request, 2026-10-05).

### Questions for Ryan: how to write them

- Ask only things engineering can't answer from data, such as how a rep would react, what a rep expects, what sales would call the right outcome, which accounts or reps matter most, or whether a default matches how reps really work.
- Each question should come from something real in the window: a decision pending, a default chosen on a guess, or a surprise in the data. Add a one-line reason that says what changes depending on his answer.
- Ask 2 to 4 per workstream, each a closed or either/or question where possible ("would a rep rather X or Y?"), so he can answer in one line.
- Don't ask for things already decided in the ticket. Don't ask permission for engineering calls.

## 3. Voice rules

- **First person, past then present:** "I noticed… so I changed… and now…". Every point names the before and the after.
- **Explain through what the rep or customer experiences**, not through code. "The follow-up never got drafted", not "the floor skipped the contract branch".
- **No** file names, function names, ticket numbers, PR numbers, flags or internal step names in the spoken text. One concrete real-world example per point is welcome (e.g. "Petaluma PD showing up under Modesto").
- **Percentages** are rounded and spoken ("about 50%"), with the raw count in brackets. Don't fake precision on small samples.
- **Keep it short:** each point is 2 to 3 sentences, and each workstream can be read in about 90 seconds.
- **Be honest about status:** "in review" is not "done", "merged" is not "live", and estimates are called estimates.

## 4. Publish to the gist

- Write the doc in the scratchpad as `standup-update.md`.
- **Update rather than create.** If a combined standup gist already exists, edit it in place, with its description re-dated:
  `GH_TOKEN="$(gh auth token --user haroun-mj-ai)" gh gist edit <id> -f standup-update.md <local file>`
  then `gh gist edit <id> --desc "<workstreams>: what to say when asked for updates (<date>)"`.
  Find it with `gh gist list` under the same token. A single-workstream gist from before 2026-10-06 isn't the combined one. Leave those untouched and point to the combined gist instead.
- Create a new gist only when no combined one exists. It must be secret:
  `GH_TOKEN="$(gh auth token --user haroun-mj-ai)" gh gist create standup-update.md --desc "<workstreams>: what to say when asked for updates (<date>)"`
- Never use the active `gh` account (it lacks org access), and never make a gist public.
- Read the content back with `gh gist view <id> --raw` to confirm it landed.
- If the auto-mode classifier blocks the gist command, don't route around it. Print the exact command for the user to run with `! <command>`.

## 5. Reply

Paste the 20-second version into the chat, ready to say, along with the
three most notable live numbers (anything surprising first) and the
Questions for Ryan headlines. Give the gist link. Don't repeat the whole
script in the chat.
