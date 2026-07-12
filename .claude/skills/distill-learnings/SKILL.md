---
name: distill-learnings
description: Runs the periodic docs/LEARNINGS.md to CLAUDE.md distillation pass for iam_scout. Use when Nick asks to distill learnings, review CLAUDE.md candidates, or run the distillation step.
disable-model-invocation: true
allowed-tools: Read, Grep, Glob
---

# Distill Learnings

Reviews docs/LEARNINGS.md for entries marked "Candidate for CLAUDE.md: Yes"
and proposes CLAUDE.md additions as a diff in chat. Never writes to
CLAUDE.md directly, by any tool.

## Steps

1. Read docs/LEARNINGS.md. Note the `<!-- distilled through: ... -->` marker
   near the top. Review every entry after that marker (or all entries if the
   marker says "never" or is missing/stale).

2. Collect every entry marked **Candidate for CLAUDE.md: Yes**.

3. Read the current root CLAUDE.md in full. For each candidate, check
   whether its substance is already present — even if the wording differs
   from the LEARNINGS.md entry. If it's already covered, note it as
   already-applied and skip it. Do not propose a diff for something
   CLAUDE.md already says.

4. For each candidate that is genuinely new, draft the smallest CLAUDE.md
   addition that captures the durable rule — consistent with CLAUDE.md's
   own "stay small and curated" principle. Present it as a unified diff in
   the chat response, one candidate per diff hunk, each traceable to its
   LEARNINGS.md entry.

5. **Never write to CLAUDE.md.** Not via Edit/Write/MultiEdit (the
   PreToolUse hook blocks these — that's expected, don't retry or work
   around a block), and not via Bash redirection, `sed`, heredocs, or any
   other mechanism. This skill has no Bash access at all (see
   `allowed-tools` above) specifically so it can't. If a diff is approved,
   Nick applies it himself or asks separately — this skill only proposes.

6. Update the `<!-- distilled through: ... -->` marker line at the top of
   docs/LEARNINGS.md to reference the newest entry just reviewed (heading +
   date), regardless of whether it produced a new diff. This line is a
   state pointer, not a log entry — updating it is not the same as editing
   a historical entry. If you disagree with treating this line as mutable
   under the file's append-only convention, skip this step and say so in
   the summary instead.

## Output

End with a short summary: candidates found, which were already applied
(skipped), which are newly proposed (with diff), and whether the marker
was updated.

## Out of scope

- Any entry marked "Candidate for CLAUDE.md: No" — those are process notes
  or pending decisions, not proposals.
- Anything in entra-scripts/ or docs/ENTRAID_POWERSHELL_PROJECT_PLAN.md.
- Resolving any "pending Nick's decision" item flagged in LEARNINGS.md
  (e.g. the hook basename-matching question) — distillation promotes
  settled candidates, it doesn't make open calls.
