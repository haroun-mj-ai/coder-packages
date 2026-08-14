# <Title>

- **Ticket:** ENG-<id>
- **Status:** Draft | Approved | In Progress | Completed
- **Scope:** Light
- **Repos touched:** <repo>
- **Date:** YYYY-MM-DD

Used only for tasks tiered "Light" per implement-issue's Phase A step 2: a single file or a
small handful in one repo, no new endpoint/schema/model field/migration, no
cross-repo touch, no architectural decision. If writing this and the change
turns out to have a real interaction surface, stop and switch to
`plan-template.md` instead — that is a sign it was mis-scoped as light.

## What & why

One or two sentences: the problem and the fix. No survey of alternatives — if
there is a leading alternative worth naming, this was not light.

## Change

- `path/to/file.ext:LINE`: what changes, specifically enough that there is
  nothing to invent. Name the function or field.

## Test

The one test that fails before this change and passes after:
`<command>::<test name>`.

## Verification

The one thing to check by hand (curl or click) that proves it works end to
end. If there is a real interaction surface to check here, this was not
light — go write the full plan instead.
