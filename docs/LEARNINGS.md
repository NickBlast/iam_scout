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

---

## 2026-07-09 — MCP doc-lookup call audit (Microsoft Learn / Context7)

**What was built/changed:** Audited actual MCP tool-call history across all
`.jsonl` session transcripts under
`~/.claude/projects/c--Users-nlund--projects-iam-scout/` (grepped for real
`mcp__claude_ai_Microsoft_Learn__*` / `Context7` tool_use entries, not just
string mentions — the raw grep count included false positives from
`ToolSearch` result text listing the tool name). No Context7 calls were made
in any session; all doc-lookup calls were Microsoft Learn.

**Audit result — 7 real doc-lookup calls found, classified:**
1. `7a727dad` 02:29:16 — `microsoft_docs_search` "Get-MgApplication ...
   pagination -All parameter"
2. `7a727dad` 02:29:17 — `microsoft_docs_search` "Get-MgApplication required
   permissions ... Application.Read.All scope" (same assistant turn as #1,
   same cmdlet) → **(a) mergeable** — #1 and #2 answer two sub-questions
   about the same cmdlet and were issued back-to-back; one query asking for
   parameters/pagination and required scope together would have covered
   both.
3. `7a727dad` 02:36:45 — `microsoft_docs_search` "Get-MgApplicationOwner ...
   list owners" → **(c) necessary** — different cmdlet, added once the
   owners feature was actually being built, ~7 min after #1/#2 resolved.
4. `abbd4cbb` 19:06:50 — `microsoft_docs_search` "Connect-MgGraph app-only
   authentication client secret ClientSecretCredential" → **(c) necessary**.
5. `abbd4cbb` 19:06:51 — `microsoft_code_sample_search` (same query, next
   tool call, 1s later) → **(c) necessary** — this is the MCP server's own
   documented workflow (search for breadth, then code-sample for snippets),
   not redundant.
6. `abbd4cbb` 19:08:13 — `microsoft_docs_search` "ConvertFrom-SecureString
   DPAPI encryption ... Windows Data Protection API" → **(c) necessary**,
   distinct topic (secret storage, not Graph auth).
7. `f91e5898` 19:22:21 — `microsoft_docs_search` "Connect-MgGraph app-only
   authentication client secret ClientSecretCredential PSCredential" →
   **(b) repeated** — near-identical query to #4, ~16 minutes later, in a
   different session-transcript file from the same same-day work arc (likely
   a session boundary/compaction, not a genuinely new question). The answer
   from #4 was already available and should have been reused instead of
   re-querying.

**Before/after estimate if the batching rule below had been applied:** 7
calls → 5 calls (merge #1+#2 into one call: −1; drop #7 as redundant: −1).
That's a ~29% reduction in doc-lookup calls, with zero loss of information
in either case (the merged query and the reused answer cover the same
ground).

**Efficiency note:** The raw `grep -c` count across files (20 total
occurrences of the string `mcp__claude_ai_(Microsoft_Learn|Context7)`) was
not the real call count — most matches were the tool name appearing inside
`ToolSearch` result payloads or system-reminder text, not actual `tool_use`
blocks. Counting real MCP calls requires filtering to `"type":"tool_use"`
entries with a matching `name` field, not a flat string grep.

**Candidate for CLAUDE.md:** Yes — see proposed diff below (not applied).

---

## 2026-07-09 — Extracted Graph auth into iam-scout-graph-auth module

**What was built/changed:** Tagged `pre-graph-auth-module` as the rollback
point, then extracted Graph app-only auth (cert + client-secret paths), the
DPAPI credential store/`-ResetCredential` logic, and the missing-module
install check out of `Export-EntraAppRegistrations.ps1` (left untouched, read
only as reference) into a new module at
`entra-scripts/modules/iam-scout-graph-auth/`. Created
`entra-scripts/export-entra-app-registrations-v2.ps1`, which imports the
module and keeps only Graph data retrieval + Excel export. Archived a dated
copy of the original to `.archive/` (gitignored — convenience only, not the
rollback mechanism) and added `.archive/` to `.gitignore`.

**MCP audit for this task:** 2 `microsoft_docs_search` calls total, one for
`Connect-MgGraph` app-only auth (cert `-CertificateThumbprint`/
`-CertificateName` params + client-secret `-ClientSecretCredential`, batched
into a single query per the batching rule) and one for PowerShell module
manifest structure + `Get-Verb`/approved-verb naming (also batched: manifest
keys, `FunctionsToExport`, and verb rules in one call). Zero redundant calls,
consistent with the CLAUDE.md MCP usage rule added earlier today.

**Naming-convention conflict resolution:** The task specified two naming
conventions that look contradictory at first glance: all new file/folder
names lowercase-hyphenated (`iam-scout-graph-auth.psd1`,
`export-entra-app-registrations-v2.ps1`), but exported *function* names must
stay PascalCase `Verb-Noun` using only `Get-Verb`-approved verbs
(`Connect-IamScoutGraph`, not `connect-iamscoutgraph`). Resolved by treating
these as two independent naming domains — filesystem naming vs. PowerShell
command naming — and applying each convention only within its own domain.
`Get-Verb` (verified via Microsoft Learn) confirmed `Connect`, `Disconnect`,
and `Initialize` are all approved verbs, so
`Connect-IamScoutGraph`/`Disconnect-IamScoutGraph`/
`Initialize-IamScoutRequiredModule` needed no substitution.

**Validation results (both required checks):**
1. *Documentation check:* auth code matches current Microsoft Learn guidance
   — `Connect-MgGraph -ClientSecretCredential <pscredential>` for the secret
   path (`PSCredential` UserName = client id, password = secret) and
   `Connect-MgGraph -ClientId -TenantId [-CertificateThumbprint |
   -CertificateName]` for the certificate path, both confirmed against
   `graph-powershell-1.0` docs fetched this session.
2. *Live functional test:* ran `Export-EntraAppRegistrations.ps1` and
   `export-entra-app-registrations-v2.ps1` back-to-back against the same test
   tenant (existing stored DPAPI secret, `-IncludeOwners` on both) and
   diffed the two `.xlsx` outputs field-by-field
   (`DisplayName`, `AppId`, `Id`, `SignInAudience`, `PublisherDomain`,
   `Owners`, `CreatedDateTime`) after sorting both by `AppId`. **Result: 3/3
   rows matched on every field, zero mismatches.** The v2 script is a
   verified behavioral drop-in for the original outside of the internal
   auth-code path.

**Candidate for CLAUDE.md:** Yes — see proposed diff (module location/naming,
rollback-tag convention, and a standing dual-validation requirement for any
`entra-scripts/` change) presented for review, not yet applied.

---

## 2026-07-09 — Expanded app registration export to full `application` schema + multi-sheet workbook

**What was built/changed:** Tagged `pre-app-registration-expand` as the rollback
point. `entra-scripts/export-entra-app-registrations-v2.ps1` now selects the
full documented set of top-level Microsoft Graph `application` resource
properties (39 properties; `logo` excluded — Stream type, not retrievable via
list `$select`) instead of the original 6-field subset, and exports to a
single workbook with 7 possible worksheets: `Core` (one row per app, always
written even for a 0-app tenant guard case) plus `RedirectUris`,
`RequiredResourceAccess`, `KeyCredentials`, `PasswordCredentials`, `AppRoles`,
`Oauth2PermissionScopes` — each row joined back to `Core` via `AppId`.
Collection sheets are omitted entirely when zero apps have any entries for
that collection (`ImportExcel`/`Export-Excel` requires at least one row per
worksheet); `Core` is unconditionally present regardless. Complex/nested
top-level properties that aren't broken into their own sheet (verifiedPublisher,
certification, info, optionalClaims, parentalControlSettings,
requestSignatureVerification, servicePrincipalLockConfiguration, addIns, and
the non-`oauth2PermissionScopes` parts of `api`/`web`) are compact-JSON-
serialized into `*Json` columns on `Core` rather than guessed at and flattened,
so no property name is fabricated. Did not modify
`entra-scripts/modules/iam-scout-graph-auth/` or the original
`Export-EntraAppRegistrations.ps1` (out of scope for this task).

**Property list source:** Microsoft Graph `application` resource type v1.0
reference (`learn.microsoft.com/graph/api/resources/application`), fetched in
full (not just the paginated `microsoft_docs_search` excerpts, which only
return partial property tables per call) via `microsoft_docs_fetch`. Cross-
checked every property name against the live
`Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication` .NET type via
`[Type]::GetProperties()` — this caught one naming mismatch the Graph API
docs didn't warn about (see Errors below). Also fetched `apiApplication` to
confirm `oauth2PermissionScopes` lives under `api`, not top-level, so the
Core select list requests `api` and the sheet-builder reads
`$app.Api.Oauth2PermissionScopes`.

**Secret-value confirmation (explicit, per task requirement):** Fetched
`passwordCredential` and `keyCredential` resource type docs. Confirmed
`passwordCredentials.secretText` is documented as "Read-only; ... only
returned during the initial POST request to addPassword. There is no way to
retrieve this password in the future" — i.e., a `GET`/list call (which is all
this script ever does) can never return the actual secret value, confirmed
both by the doc and by the live test (the `PasswordCredentials` sheet has no
secret-value column; only `KeyId`, `CredentialDisplayName`, `Hint`,
`StartDateTime`, `EndDateTime`). Confirmed `keyCredentials.key` (the raw
certificate bytes) similarly requires an explicit `$select` on a
single-object `GET` and is "always `null`" otherwise — since this script
uses `-All` (a list call), `key` is always null regardless, so it was
excluded from the `KeyCredentials` sheet columns entirely rather than
included as a column that would always read empty.

**Naming mismatch caught by SDK cross-check:** The Graph API property is
`oauth2RequiredPostResponse`, but the deserialized
`Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication` .NET property is
named `Oauth2RequirePostResponse` (no "d" on "Required"). First live test run
failed with `Write-Error: The property 'Oauth2RequiredPostResponse' cannot be
found on this object`. Fixed by running
`[Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication].GetProperties().Name`
and diffing against every property name used in the script (also
pre-emptively checked `Api`, `Web`, `KeyCredential`, `PasswordCredential`,
`AppRole`, `PermissionScope`, `RequiredResourceAccess`, `ResourceAccess`
nested types the same way) — all other names matched on the first pass.
**Fix/learning:** when consuming a PowerShell SDK's deserialized objects,
verify property names against the SDK's own .NET type via `GetProperties()`,
not just against the Graph REST API's camelCase doc names — the SDK does not
always PascalCase a REST property name literally.

**Validation results (both required checks):**
1. *Documentation check:* full property list, `-Property`/`$select` support,
   and secret-metadata-only behavior all confirmed against current Microsoft
   Learn `graph-rest-1.0` docs (see above).
2. *Live functional test:* ran the original `Export-EntraAppRegistrations.ps1`
   and the expanded `export-entra-app-registrations-v2.ps1` back-to-back
   against the same test tenant (3 app registrations, `-IncludeOwners` on
   both, existing stored DPAPI secret — no write/create/delete calls made).
   Compared the original's single sheet against v2's `Core` sheet on every
   field the original ever emitted (`DisplayName`, `AppId`, `Id`,
   `SignInAudience`, `PublisherDomain`, `CreatedDateTime`, `Owners`):
   **3/3 rows matched on every field, zero mismatches.** Confirmed v2's new
   sheets: `RequiredResourceAccess` populated (44 rows across the 3 apps),
   `PasswordCredentials` populated (2 rows, metadata only, no secret values),
   `Core` present for all 3 apps regardless; `RedirectUris`, `KeyCredentials`,
   `AppRoles`, `Oauth2PermissionScopes` sheets correctly omitted because none
   of the 3 test apps have any entries in those collections.

**Efficiency note:** a stray `pwsh -Command` invocation from the Bash tool
using a forward-slash bash-style path (`/c/Users/...`) as an `-OutputDirectory`
argument silently wrote output to a bogus `C:\c\Users\...` directory instead
of erroring — `Join-Path`/`New-Item -Force` happily created the nonsense path
rather than failing. **Fix/learning:** when passing paths from the Bash tool
into a `pwsh -Command` string, always convert to native Windows
backslash-and-drive-letter form first; a "successful" run with no error is not
proof the output landed where intended — verify the reported output path
looks like a real Windows path before trusting it.

**Candidate for CLAUDE.md:** No new durable rule beyond what's already
captured (dual-validation requirement, read-only testing) — the SDK
property-name cross-check and the bash-path-into-pwsh gotcha are one-off
process findings, not repo conventions.

---

## 2026-07-09 — PreToolUse hook enforcing the CLAUDE.md no-self-edit rule

**What was built:** `.claude/hooks/protect-claude-md.sh`, a PreToolUse hook
script that reads the tool call's JSON from stdin, extracts
`tool_input.file_path` (via `python3 -c` with a `grep`/`sed` fallback if
`python3` isn't present), and if the file's basename is `CLAUDE.md`, writes a
rejection message to stderr and exits 2 — which blocks the tool call. Any
other file path exits 0 (allowed). Registered in a new project-level
`.claude/settings.json` (checked into git, distinct from the existing
gitignored `.claude/settings.local.json`) as a `PreToolUse` hook matched to
`Edit|Write|MultiEdit`.

**Why a hook instead of relying on the existing CLAUDE.md instruction alone:**
CLAUDE.md already said "never edit this file directly," but that was advisory
only — a model could still forget or talk itself into an exception. A
PreToolUse hook makes the block mechanical or tool-level rather than
memory/instruction-following-based.

**Test results:**
1. `Edit` against `CLAUDE.md` → blocked, stderr showed the expected message
   (`PreToolUse:Edit hook error: ... do not retry this write.`).
2. `Write` against `CLAUDE.md` → blocked the same way.
3. `Edit` against `docs/README.md` (unrelated file, added then reverted a
   one-line test change) → succeeded normally, confirming the hook only
   matches on `CLAUDE.md`'s basename and doesn't affect other files.

**Known gap (deliberately deferred):** the hook only intercepts the `Edit`,
`Write`, and `MultiEdit` tools. Bash-based file mutation (`sed -i`, `cat >`,
`echo >>`, PowerShell `Set-Content`, etc.) targeting `CLAUDE.md` is not
covered — those go through the `Bash`/`PowerShell` tools, not a file-edit
tool, so this hook's matcher never sees them. Not closing this gap now since
it adds a second hook matched on `Bash|PowerShell` that would need to parse
shell command strings for a `CLAUDE.md` target, which is more failure-prone
(quoting, indirection, heredocs) than the benefit currently justifies. Revisit
only if a Bash-based edit of CLAUDE.md is actually attempted in practice.

**Candidate for CLAUDE.md:** Yes — one line noting the no-self-edit rule is
now hook-enforced, not just advisory. Proposed separately as a diff for
review (not applied directly, per the very rule being enforced).
