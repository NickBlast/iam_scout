# IAM Scout — Self-Updating Documentation Loop

## Why two files, not one

`CLAUDE.md` is loaded into context on **every** session. If Claude Code appends
a new paragraph to it after every task, the file grows without bound and the
token cost of *loading your rules* eventually exceeds the tokens saved by
having them. So the system needs two files with different jobs:

| File | Purpose | Growth | Who edits it |
|---|---|---|---|
| `CLAUDE.md` | Durable, curated operating rules and gotchas | Small, stays flat over time | Claude Code proposes diffs; **you** approve/merge |
| `LEARNINGS.md` | Append-only, dated raw log of what happened | Grows freely | Claude Code writes directly, no approval needed |

`LEARNINGS.md` is cheap to write to because it's *not* loaded every session —
only read during periodic distillation. `CLAUDE.md` stays small because
nothing lands there without your sign-off.

---

## The loop

1. **Task in** — you hand Claude Code a prompt/task.
2. **Work to completion** — normal execution, uninterrupted.
3. **End-of-task self-review** (last step before Claude Code reports done) —
   run the checklist below. Takes a few sentences, not a report.
4. **Append to `LEARNINGS.md`** — raw, unfiltered, timestamped. No judgment
   call needed here; err toward logging.
5. **Periodic distillation** (you trigger this — e.g. "distill learnings" every
   N sessions, or whenever the file feels long) — a separate pass reads
   `LEARNINGS.md` and proposes a **diff** to `CLAUDE.md`: new rules, corrected
   assumptions, patterns to adopt or avoid.
6. **You approve the diff** — edit, reject, or accept. This is the guardrail
   against Claude Code reinforcing a wrong pattern it only *thinks* worked.
7. **Merge into `CLAUDE.md`** — and optionally prune/consolidate older
   `LEARNINGS.md` entries that are now captured upstream (archive, don't
   delete).

This keeps step 3–4 (happens constantly) cheap and non-blocking, and keeps
step 5–6 (the only place tokens/rules actually compound) gated by you.

---

## Step 3: End-of-task self-review checklist

Append this to your Claude Code system prompt / CLAUDE.md so it runs
automatically at the end of every task, before Claude Code says it's done:

```
Before finishing, answer briefly (skip any that don't apply — don't pad):
1. Did I hit an error or wrong assumption that cost extra iterations? What was it, and what's the fix for next time?
2. Did I discover something about this codebase/API/service that wasn't documented anywhere?
3. Is there a faster or lower-token way I could have approached this that I only figured out partway through?
4. Nothing to note? Say so in one line and stop.

Write anything from 1–3 as a single dated entry in LEARNINGS.md. Do not edit CLAUDE.md directly.
```

The last line is the key guardrail — Claude Code is *never* authorized to
self-edit `CLAUDE.md`. Only you promote things into it.

---

## Entry template: `LEARNINGS.md`

Append-only, most recent at the bottom (or top — pick one and stay consistent).

```markdown
## 2026-07-09 — Entra app registration export

**What was built/changed:** Export-EntraAppRegistrations.ps1, Phase 1 scope.

**Error hit:** Get-MgApplication paginates silently past 999 results without
-All; first export was missing ~40 apps and looked complete.

**Fix/learning:** Always pass -All explicitly with Get-MgApplication, don't
rely on default page behavior. Add this as a standing rule.

**Efficiency note:** N/A

**Candidate for CLAUDE.md:** Yes — "PowerShell/Graph gotchas" section
```

Keep entries short. The point is raw material for distillation, not prose.

---

## Entry template: `CLAUDE.md` additions (post-approval)

Organize `CLAUDE.md` by durable category, not chronologically — this is what
keeps it flat instead of turning into a second changelog:

```markdown
## AWS collection rules
- Never call secret-reading API methods.
- Always use get_paginator() for list operations.

## PowerShell / Graph gotchas
- Get-MgApplication requires -All explicitly; it paginates silently otherwise.

## Known inefficiencies to avoid
- [pattern] costs N extra tool calls; use [alternative] instead.
```

Each bullet should be something you'd tell a new engineer once, not a log of
when it was learned — dates belong in `LEARNINGS.md`, not here.

---

## Distillation prompt (run periodically, not automatically)

```
Read LEARNINGS.md since the last distillation marker. Group related entries,
drop one-offs that won't recur, and propose a diff to CLAUDE.md — additions,
edits to existing rules, or removals if something's now obsolete. Show the
diff, don't apply it. Wait for approval.
```

After you approve and merge, mark the distillation point in `LEARNINGS.md`
(e.g. `<!-- distilled through 2026-07-09 -->`) so the next pass only reads new
entries.

---

## Guardrails summary

- Claude Code writes to `LEARNINGS.md` freely; **never** to `CLAUDE.md` directly.
- Distillation is a distinct, human-triggered step — not automatic.
- You approve every `CLAUDE.md` diff before merge.
- Old `LEARNINGS.md` entries get archived once distilled, not deleted (keeps
  history if you want to revisit a decision).
- If `CLAUDE.md` starts creeping past a page or two, that's the signal to
  prune/consolidate, not to keep appending.
