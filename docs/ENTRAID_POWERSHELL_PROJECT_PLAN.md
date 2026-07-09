# EntraID / PowerShell — Project Plan (2026-07-09)

## Status of the broader IAM Scout plan

The original multi-cloud vision (AWS + Azure collectors, FastAPI backend,
React dashboard, SQLite) was discussed and designed but **never made it into
the repo** — no `IAM_SCOUT_PROJECT_PLAN.md`, no `CLAUDE.md`, no git history.
The only thing that actually exists on disk is the EntraID/PowerShell work.

This plan **supersedes that broader plan for now**. The multi-cloud/Python
work is deferred, not abandoned — it resumes once the EntraID/PowerShell
track is stable and documented in-repo.

---

## Phase 0 — Repo hygiene (do first, before any new feature work)

Not glamorous, but everything after this depends on it existing:

- [ ] `git init` + initial commit of current state
- [ ] `.gitignore` — exclude generated exports (`*.xlsx`, timestamped output
      files), local credential/token cache files
- [ ] `CLAUDE.md` — seed with the conventions already implicit in
      `Export-EntraAppRegistrations.ps1` (see below)
- [ ] Decide `entra-scripts/` purpose — likely destination for Phase 2
      scripts, or rename/remove if not needed
- [ ] Dependency manifest — a `requirements.psd1` or documented
      `Install-Module` block listing `Microsoft.Graph.Authentication`,
      `Microsoft.Graph.Applications`, `ImportExcel` with version pins

## Phase 1 — App Registration Export (COMPLETE)

`Export-EntraAppRegistrations.ps1`:
- Connects to Microsoft Graph app-only (client credential, DPAPI-encrypted
  local storage)
- Pulls app registrations via `Get-MgApplication`
- Exports `DisplayName`, `AppId`, `Id`, `SignInAudience`, `CreatedDateTime`,
  `PublisherDomain`, optional `Owners` (`-IncludeOwners` switch)
- Explicitly out of scope: enterprise apps / service principals, secret
  values, sign-in/audit logs

No further work needed here except what Phase 0 hygiene surfaces.

## Phase 2 — Enterprise Apps, Secrets Metadata, Log Data

Scope to define precisely before starting (this is the boundary that
matters most — write it down before touching code):

- **Enterprise apps / service principals** — `Get-MgServicePrincipal`,
  same export pattern as Phase 1
- **Secrets metadata** — expiration dates, key IDs, credential *type* only.
  Explicitly **never** the secret values themselves — same rule as AWS
  collection (never call secret-reading methods)
- **Log/sign-in data** — `Get-MgAuditLog*` / `Get-MgReport*`, scope TBD
  (date range, retention, PII handling need a decision before implementation)

Out of scope for Phase 2 unless explicitly revisited: AWS, FastAPI backend,
dashboard, SQLite storage — those stay parked until this track is stable.

## CLAUDE.md seed content (once Phase 0 creates the file)

```markdown
# iam_scout — EntraID/PowerShell track

## Commands
- Run export: pwsh ./Export-EntraAppRegistrations.ps1
- (add build/test commands here once they exist)

## Conventions
- PowerShell 7, Microsoft.Graph.Applications module, app-only auth
- Credentials: DPAPI-encrypted local storage only, never logged/exported
- Always pass -All explicitly to Graph list cmdlets (they paginate silently otherwise)
- Never export secret values — metadata only (expiry, key ID, type)
- No enterprise app / service principal calls until Phase 2 is explicitly scoped
- No audit/sign-in log calls until Phase 2 is explicitly scoped

## Out of scope (parked, not abandoned)
- AWS collector, FastAPI backend, React dashboard, SQLite — deferred until
  EntraID/PowerShell track is stable and documented
```

---

## Open questions to resolve, not assumed

- Does `entra-scripts/` become the home for Phase 2 scripts, or is Phase 2
  a continuation of the same single script?
- Should generated `.xlsx` exports live outside the repo entirely (e.g. a
  local `output/` folder that's gitignored) rather than the repo root?
- When does the multi-cloud Python plan resume — fixed trigger (Phase 2
  complete) or open-ended?
