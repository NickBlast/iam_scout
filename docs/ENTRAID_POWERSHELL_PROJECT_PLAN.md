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

- [x] `git init` + initial commit of current state
- [x] `.gitignore` — exclude generated exports (`*.xlsx`, timestamped output
      files), local credential/token cache files
- [x] `CLAUDE.md` — seed with the conventions already implicit in
      `Export-EntraAppRegistrations.ps1` (see below)
- [x] Decide `entra-scripts/` purpose — confirmed as the permanent home for
      all EntraID scripts (Phase 1's export script plus future Phase 2 scripts)
- [x] Dependency manifest — `requirements.psd1` listing
      `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications`,
      `ImportExcel` (versions intentionally unpinned until a known-good
      combination is verified)
- [ ] `output/` directory exists and is gitignored, but the script's
      `-OutputDirectory` default still points at the current directory —
      decide whether to change the script default or leave it opt-in via
      the flag

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

- **Enterprise apps / service principals (COMPLETE, 2026-07-12)** — extended
  `export-entra-app-registrations-v2.ps1` (same script, same workbook — no
  new script, no changes to `iam-scout-graph-auth`) with a
  `Get-ServicePrincipalInventory` function that, for each app registration's
  `Core` row, resolves its Service Principal and joins six new sheets back to
  `Core` via `AppId`:
  - `ServicePrincipals` — one row per resolved SP (`Get-MgServicePrincipal
    -Filter "appId eq '<appId>'"`); `Application.Read.All` (already
    consented). No dedicated "get by AppId" SDK parameter exists — `-Filter`
    is the practical equivalent of the REST `servicePrincipals(appId='{appId}')`
    addressing.
  - `SPKeyCredentials` / `SPPasswordCredentials` — credential metadata only
    (`KeyId`, display name, hint/type/usage, start/end dates); never a secret
    value or raw key, same guarantee as Phase 1 (Graph never returns them on
    a list call regardless of `$select`).
  - `SPAppRoleAssignments` (granted application permissions) —
    `Get-MgServicePrincipalAppRoleAssignment`, `Application.Read.All`.
  - `SPOauth2PermissionGrants` (granted delegated permissions) —
    `Get-MgServicePrincipalOauth2PermissionGrant`. **Needs `Directory.Read.All`**,
    broader than `Application.Read.All` — confirmed against Microsoft Learn
    (`graph-rest-1.0` `serviceprincipal-list-oauth2permissiongrants`). The
    script degrades gracefully: a per-SP try/catch warns once and leaves this
    sheet's rows empty for affected SPs rather than aborting the export if
    `Directory.Read.All` isn't consented. (On the test tenant it already was
    consented, so this path was exercised as the success case, not the
    failure case — see LEARNINGS.)
  - `SPMemberOf` (group/directory-role memberships) —
    `Get-MgServicePrincipalMemberOf`, `Application.Read.All`.

  Worksheet names use an `SP`-prefixed short form (e.g. `SPAppRoleAssignments`)
  because Excel caps worksheet names at 31 characters — the fully-spelled
  `ServicePrincipal*` names would silently truncate.

  Out of scope for this pass (unchanged): creating/rotating SPs, secrets, or
  API permissions — read-only only.

- **Secrets metadata** — done as part of the above (`SPKeyCredentials`/
  `SPPasswordCredentials`); expiration dates, key IDs, credential *type*
  only. Explicitly **never** the secret values themselves.
- **Log/sign-in data** — `Get-MgAuditLog*` / `Get-MgReport*`, scope TBD
  (date range, retention, PII handling need a decision before implementation)
  — not started.

Out of scope for Phase 2 unless explicitly revisited: AWS, FastAPI backend,
dashboard, SQLite storage — those stay parked until this track is stable.

## Phase 3 — Identity & Tenant Configuration Inventory

A new read-only inventory covering entity domains that do **not** join to the
app-registration workbook's `Core` sheet by `AppId` — users, directory roles,
and tenant-level cross-tenant access configuration are a different entity
domain than app registrations. Phase 3 therefore lives in a **new script**,
`entra-scripts/export-entra-identity-inventory.ps1`, importing the existing
`iam-scout-graph-auth` module unchanged and producing its own timestamped
workbook (`EntraIdentityInventory_<timestamp>.xlsx`). Combining it into the
app-registration export was considered and rejected: the sheets would share
no join key with `Core`, and the two exports have different permission
footprints (Phase 3 adds `Policy.Read.All`), so keeping them separate lets
the app-registration export keep running under its narrower consent.

Scope (all read-only `Get-Mg*` calls, zero write/create/delete):

1. **Users** — `Get-MgUser -All` (module `Microsoft.Graph.Users`, new
   dependency in `requirements.psd1`). One `Users` sheet: `Id`,
   `UserPrincipalName`, `DisplayName`, `AccountEnabled`, `UserType`
   (Member/Guest), `CreatedDateTime`. Least-privilege permission to be
   verified via `Find-MgGraphCommand -Command Get-MgUser` + Microsoft Learn;
   expected to be covered by the tenant's existing `Directory.Read.All`
   consent (confirm, don't assume).

2. **Directory roles** — `Get-MgDirectoryRole` (activated roles only) +
   `Get-MgDirectoryRoleMember` per role (module
   `Microsoft.Graph.Identity.DirectoryManagement`, new dependency). Two
   sheets: `DirectoryRoles` (`RoleId`, `RoleTemplateId`, `DisplayName`,
   `Description`) and `DirectoryRoleMembers` (`RoleId`, `RoleDisplayName`,
   `MemberId`, `MemberType`, `MemberDisplayName` — member type/display name
   resolved from the returned `directoryObject`'s `AdditionalProperties`,
   since the member cmdlet returns bare directory-object references).
   **Known gap (documented, not worked around):** this surfaces only
   *activated* directory roles and their current members — PIM-eligible
   assignments that haven't been activated do not appear.

3. **Secrets expiry status (enhancement to the Phase 2 export, not a new
   collection)** — a computed `ExpiryStatus` column (`Expired`,
   `ExpiringSoon`, `OK`; threshold configurable via an
   `-ExpiringSoonThresholdDays` parameter, default 30) added to the four
   existing credential sheets in `export-entra-app-registrations-v2.ps1`
   (`KeyCredentials`, `PasswordCredentials`, `SPKeyCredentials`,
   `SPPasswordCredentials`), computed from the already-captured
   `EndDateTime`. No new Graph calls.

4. **Cross-tenant access configuration** —
   `Get-MgPolicyCrossTenantAccessPolicyDefault` (tenant baseline) +
   `Get-MgPolicyCrossTenantAccessPolicyPartner -All` (per-partner overrides)
   (module `Microsoft.Graph.Identity.SignIns`, new dependency). Two sheets:
   `CrossTenantAccessDefault` (one row) and `CrossTenantAccessPartners` (one
   row per partner: `TenantId`, B2B collaboration inbound/outbound access
   type, B2B direct connect inbound/outbound, service-provider flag).
   Requires **`Policy.Read.All`** — expected to be a genuinely new
   admin-consent requirement for the test tenant; must be confirmed against
   the tenant's actual consent state (`Get-MgContext` after app-only
   connect) and flagged before live testing, not silently assumed either way.
   If it isn't consented, the script degrades gracefully (warn, leave the
   two sheets empty) rather than aborting the user/role export.

Validation: the standing dual-validation rule applies (Microsoft Learn
permission/API check per cmdlet before coding; live read-only functional
test against the test tenant with actual row counts and field-level results
reported). Docs pass and script pass are separate commits.

Out of scope for Phase 3: sign-in/audit log data (`Get-MgAuditLogSignIn` /
`Get-MgAuditLogDirectoryAudit`) — deferred; PIM-eligible role assignments
(noted as a gap above, not collected).

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
