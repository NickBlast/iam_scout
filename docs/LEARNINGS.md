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
