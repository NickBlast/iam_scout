# iam_scout — EntraID/PowerShell track

Project context lives in `docs/` — check @docs/README.md before assuming
something doesn't exist or isn't documented.

## Commands
- Run export: `pwsh ./entra-scripts/Export-EntraAppRegistrations.ps1 -TenantId <tenant> -ClientId <appId>`
  - First run prompts for the client secret and stores it (DPAPI); later runs are silent.
  - `-OutputDirectory <path>` — write the .xlsx elsewhere (default: current directory; use `output/` per repo convention).
  - `-IncludeOwners` — also resolve app owners (one extra Graph call per app).
  - `-InstallMissingModules` — auto-install missing required modules instead of stopping.
  - `-ResetCredential` — discard the stored secret and re-prompt (e.g. after rotation).
- (add build/test commands here once they exist)

## Conventions
- PowerShell 7, requires `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications`,
  `ImportExcel` (never the full `Microsoft.Graph` meta-module — load time).
- App-only (client-credentials) auth against Graph — no delegated/user sign-in.
- Requires the `Application.Read.All` **application** permission with admin consent.
- Client secret: captured once via secure prompt, stored DPAPI-encrypted under
  `%LOCALAPPDATA%\EntraAppExport`, never logged, exported, or passed as a parameter.
- Always pass `-All` explicitly to Graph list cmdlets (e.g. `Get-MgApplication`) —
  they paginate silently otherwise.
- `entra-scripts/` is the home for all EntraID PowerShell scripts (Phase 1's
  export script plus future Phase 2 scripts).
- Generated `.xlsx` exports go to a gitignored `output/` directory, not the repo root.
- Never export secret *values* — metadata only (expiry, key ID, type) — once
  Phase 2 adds secrets metadata collection.
- No enterprise app / service principal calls (`Get-MgServicePrincipal`, etc.)
  until Phase 2 is explicitly scoped.
- No audit/sign-in log calls (`Get-MgAuditLog*`/`Get-MgReport*`) until Phase 2
  is explicitly scoped.

## Out of scope (parked, not abandoned)
- AWS collector, FastAPI backend, React dashboard, SQLite — deferred until
  the EntraID/PowerShell track is stable and documented.

## Workflow: end-of-task self-review

Before finishing any task, answer briefly (skip any that don't apply — don't pad):
1. Did I hit an error or wrong assumption that cost extra iterations? What was it, and what's the fix for next time?
2. Did I discover something about this codebase/API/service that wasn't documented anywhere?
3. Is there a faster or lower-token way I could have approached this that I only figured out partway through?
4. Nothing to note? Say so in one line and stop.

Write anything from 1–3 as a single dated entry in `docs/LEARNINGS.md`. **Never edit this file (CLAUDE.md) directly** — propose a diff and wait for approval, per the loop in @docs/README.md.
