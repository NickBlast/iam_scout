# iam_scout — Learnings Log

Append-only. Newest entries at the bottom. See `IAM_SCOUT_LEARNING_LOOP.md` for
the workflow this file is part of. Nothing here gets promoted into
`CLAUDE.md` without an explicit review/approval pass.

<!-- distilled through: never (no CLAUDE.md exists yet) -->

---

## 2026-07-09 — Repo status snapshot / EntraID Phase 1 audit

**What was built/changed:** `Export-EntraAppRegistrations.ps1` — complete,
single-file PowerShell 7 script. Connects to Microsoft Graph app-only,
pulls app registrations via `Get-MgApplication`, exports to `.xlsx` via
`ImportExcel`. No stubs, no TODOs, full error handling.

**Scope check result:** Confirmed within Phase 1 boundaries (app
registrations only) — no `Get-MgServicePrincipal` calls, no secret values
exported, no audit/sign-in log calls. Exported fields limited to
`DisplayName`, `AppId`, `Id`, `SignInAudience`, `CreatedDateTime`,
`PublisherDomain`, optional `Owners` via `-IncludeOwners`.

**Errors/gaps found (not code bugs — process/repo gaps):**
1. Repo was never `git init`'d — no version history exists at all.
2. Neither `CLAUDE.md` nor `IAM_SCOUT_PROJECT_PLAN.md` exist in the repo,
   despite being referenced in prior planning conversations. Scope
   decisions currently live only in chat history, not in the repo.
3. A generated output file (`EntraAppRegistrations_20260709_144317.xlsx`,
   real tenant data) sits in the repo root with no `.gitignore` in place —
   would get committed as-is once git is initialized.
4. No dependency manifest (`.psd1`/lock file) for the required modules
   (`Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications`,
   `ImportExcel`) — currently just inline comments in the script.
5. `entra-scripts/` directory exists but is empty — purpose undocumented.

**Fix/learning:** Before any Phase 2 work starts, the repo needs: `git init`
+ initial commit, a `.gitignore` covering timestamped `.xlsx` exports, a
`CLAUDE.md` capturing the conventions already implicit in the script (never
export secret values, DPAPI-encrypt local credentials, use explicit `-All`
with Graph cmdlets), and a decision on what `entra-scripts/` is for.

**Efficiency note:** Auditing "plan vs. reality" cost a full repo read
because no plan document existed to check against. Once `CLAUDE.md` and a
project plan exist in-repo, this kind of audit becomes a diff instead of a
from-scratch investigation.

**Candidate for CLAUDE.md:** Yes — repo hygiene rules (git, gitignore,
manifest) and the Graph/PowerShell conventions above.

---

## 2026-07-09 — docs/ index + CLAUDE.md seed + Phase 0 hygiene

**What was built/changed:** `docs/README.md` (standing index), repo-root
`CLAUDE.md` (verified against `Export-EntraAppRegistrations.ps1` rather than
copied verbatim from the plan doc's seed), `.gitignore`, `requirements.psd1`,
`git init` + initial commit. `entra-scripts/` confirmed as the permanent home
for all EntraID scripts (user decision, not guessed). Deleted a stray
`EntraAppRegistrations_*.xlsx` containing real tenant data that predated git.

**Error hit:** Named files the user described didn't match the directory's
actual contents on the first pass — `IAM_SCOUT_LEARNING_LOOP.md` didn't
exist yet (only showed up later as `IAM_SCOUT_LEARNING_LOOP_1.md`, a save-
conflict artifact), an empty `docs/CLAUDE.md` and a `docs/status/` snapshot
existed but weren't mentioned, and `Export-EntraAppRegistrations.ps1` had
already moved from repo root into `entra-scripts/`, making the existing
status snapshot stale.

**Fix/learning:** When asked to "confirm current state" against a list of
named files, `ls`/`Glob` the containing directory first rather than reading
only the named files — catches missing/extra/renamed files in one shot
instead of surfacing them one at a time via read errors.

**Efficiency note:** Also discovered git had no `user.name`/`user.email`
configured anywhere on this machine (not just this repo) — first `git init`
on a fresh machine should expect to hit this and ask for identity up front
rather than after attempting a commit.

**Candidate for CLAUDE.md:** No — these are one-off process/environment
findings (stale docs, unset git identity), not durable rules about the
codebase itself.

---

## 2026-07-09 — CLAUDE.md verification against repo state

**What was built/changed:** Verified three CLAUDE.md claims against actual
files instead of trusting the doc: script location (`entra-scripts/`,
confirmed accurate), the `-OutputDirectory`/`-InstallMissingModules`/
`-ResetCredential` param block (confirmed accurate, quoted directly from the
script), and the `output/` directory (found **not** accurate — gitignored in
pattern only, directory never existed, script default still points at the
current directory). Created `output/` with a `.gitkeep` (using an
`output/*` / `!output/.gitkeep` gitignore pattern so the empty dir is
trackable), checked off completed Phase 0 items in
`ENTRAID_POWERSHELL_PROJECT_PLAN.md`, and left the `-OutputDirectory` default
decision as an explicit open item rather than silently deciding it.

**Error hit:** `CLAUDE.md` stated the `output/` convention as if fully wired
up when only the `.gitignore` pattern existed — a doc can drift out of sync
with reality even one commit after being "verified," so re-verify specific
claims against the filesystem, not just against the doc's own internal
consistency.

**Also discovered:** a git remote (`github.com/NickBlast/iam_scout`) and a
branch rename (`master` → `main`) appeared between sessions, outside of any
action taken here — repo state can change from outside this workflow
(user's own git commands), so check `git remote -v` / branch name rather
than assuming continuity between sessions.

**Candidate for CLAUDE.md:** No — process/verification findings, not a
durable rule.
