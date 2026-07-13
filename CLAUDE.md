# iam_scout — EntraID/PowerShell track

Project context lives in `docs/` — check @docs/README.md before assuming
something doesn't exist or isn't documented.

## MCP usage (Microsoft Learn / Context7)
- Batch related lookups into one query instead of one call per sub-question
  — e.g. a cmdlet's parameters, required scope, and pagination pattern
  belong in a single `microsoft_docs_search` call, not three.
- Before calling a doc-lookup MCP tool, check whether the same question was
  already answered earlier in this session (or a recent session on the same
  task) and reuse that answer instead of re-querying.
- Reserve MCP doc calls for genuine uncertainty (an unfamiliar cmdlet,
  version-specific behavior) — don't default to look-up-first for things
  already established in this file or answered earlier.
- If a doc lookup produces a durable technical pattern (not a one-off
  fact), capture the answer in this file's Graph/PowerShell conventions
  section via the `LEARNINGS.md` distillation step, so it's answered zero
  times in future sessions — not just fewer times per session.

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
- Graph authorization: the scripts need the documented **application**
  permissions (app-registration export: `Application.Read.All`; identity
  inventory: `Directory.Read.All`-level reads + `Policy.Read.All`) with admin
  consent, **or** an equivalent Entra directory role assigned to the app's
  service principal. The test tenant currently uses the latter — an active
  tenant-wide **Global Reader** assignment and no app-role consents at all
  (verified 2026-07-13; see LEARNINGS).
- Client secret: captured once via secure prompt, stored DPAPI-encrypted under
  `%LOCALAPPDATA%\EntraAppExport`, never logged, exported, or passed as a parameter.
- Always pass `-All` explicitly to Graph list cmdlets (e.g. `Get-MgApplication`) —
  they paginate silently otherwise.
- `entra-scripts/` is the home for all EntraID PowerShell scripts (Phase 1's
  export script plus future Phase 2 scripts).
- Reusable Graph app-only auth (cert + client-secret paths), the DPAPI
  credential store, and the missing-module install check live in
  `entra-scripts/modules/iam-scout-graph-auth/` — import it rather than
  re-implementing auth in a new script. File/folder names in `entra-scripts/`
  are lowercase-hyphenated; exported PowerShell function names stay PascalCase
  `Verb-Noun` using only `Get-Verb`-approved verbs (e.g. `Connect-IamScoutGraph`)
  — these are two independent naming domains, not a conflict.
- Non-secret `TenantId`/`ClientId` defaults live in a git-ignored
  `entra-scripts/modules/iam-scout-graph-auth/config.psd1` (see
  `config.psd1.example`), set via `Set-IamScoutGraphDefault`; the client
  secret's DPAPI-store flow is unaffected.
- Generated `.xlsx` exports go to a gitignored `output/` directory, not the repo root.
- Never export secret *values* — metadata only (expiry, key ID, type) — once
  Phase 2 adds secrets metadata collection.
- No enterprise app / service principal calls (`Get-MgServicePrincipal`, etc.)
  until Phase 2 is explicitly scoped.
- No audit/sign-in log calls (`Get-MgAuditLog*`/`Get-MgReport*`) until Phase 2
  is explicitly scoped.
- Rollback convention for any refactor: tag the pre-change commit
  (`git tag pre-<change-name>`) before starting — that tag is the
  authoritative rollback mechanism. A convenience copy of the old file(s) may
  go in `.archive/` (gitignored) for quick side-by-side reading, but it is
  never the thing you roll back to.
- Standing rule: any change to code under `entra-scripts/` is not complete
  until both (a) a documentation check confirms the relevant cmdlet/API usage
  against current Microsoft Learn guidance, and (b) a live functional test
  runs the changed script against the test tenant and the output is compared
  field-for-field/row-for-row against a fresh run of the prior version (or,
  if there is no prior version, sanity-checked against expected tenant data).
  Report the actual diff, not just pass/fail.
- Live functional tests must be read-only against the tenant — no
  write/create/delete Graph calls as a side effect of validation.

## Out of scope (parked, not abandoned)
- AWS collector, FastAPI backend, React dashboard, SQLite — deferred until
  the EntraID/PowerShell track is stable and documented.

## Workflow: end-of-task self-review

### Verifying repo state
Don't trust `docs/`, named file lists in requests, or assumed session
continuity as ground truth about repo state — it drifts (files move, git
identity/remote/branch can change outside this workflow). Before confirming
or acting on a claim about repo state, check directly (`Glob`/`ls` the
directory, `git status`/`git remote -v`) rather than trusting the doc or the
last-known state.

Before finishing any task, answer briefly (skip any that don't apply — don't pad):
1. Did I hit an error or wrong assumption that cost extra iterations? What was it, and what's the fix for next time?
2. Did I discover something about this codebase/API/service that wasn't documented anywhere?
3. Is there a faster or lower-token way I could have approached this that I only figured out partway through?
4. Nothing to note? Say so in one line and stop.

Write anything from 1–3 as a single dated entry in `docs/LEARNINGS.md`. **Never edit this file (CLAUDE.md) directly** — propose a diff and wait for approval, per the loop in @docs/README.md. This is now enforced by a PreToolUse hook (`.claude/hooks/protect-claude-md.sh`), not just advisory.
