# Entra Connect Sync Health Monitor — Design (MVP)

A lightweight, on-prem PowerShell monitor that runs from the Entra Connect
sync server, detects two independent failure modes, and emails an alert via
an internal (unauthenticated) SMTP relay. Risk-mitigation MVP — there is no
backup sync mechanism — not a platform build.

## The two detection paths

### 1. Local sync engine errors (event log)

Every poll, `Get-IamScoutSyncEvent` queries the **Application** log via
`Get-WinEvent -FilterHashtable` for Critical/Error events (levels 1–2) from
the Entra Connect sources `ADSync` and `Directory Synchronization`.

- **Why `Get-WinEvent` and not `Get-EventLog`:** `Get-EventLog` does not
  exist on PowerShell 7 (this repo's floor) — what ships there is a stub
  that tells you it is Windows PowerShell 5.1-only. `Get-WinEvent` also
  exposes `RecordId`, the per-log monotonically increasing sequence number
  used for dedup.
- **Dedup:** the highest processed `RecordId` is persisted in
  `logs/syncmonitor-state.json`; only events strictly above it are processed
  on later polls. First run (no state) looks back
  `EventLog.FirstRunLookbackMinutes` (default 60).
- **Providers are queried one at a time** so a source name that isn't
  registered on the machine (common — which of the two names exists depends
  on the Entra Connect install) is skipped with a warning instead of
  sinking the whole poll.
- **Catalog lookup:** each event ID is resolved against
  `config/error-catalog.json` → human-readable meaning + "what to check"
  checklist. **Unmapped IDs are never dropped** — they resolve to the
  catalog's `unmapped` fallback ("review manually", `Mapped: false`) and
  still log + alert. Add new IDs to the JSON; no code change needed.

### 2. Tenant-side sync staleness (Graph heartbeat)

Independent of anything the local engine says about itself:
`Get-MgOrganization -Property onPremisesSyncEnabled,onPremisesLastSyncDateTime`
via the existing app-only auth module (`Connect-IamScoutGraph` from
`entra-scripts/modules/iam-scout-graph-auth/` — not duplicated). If the
tenant's last successful sync is older than `StalenessThresholdMinutes`
(default 45), a `STALE_SYNC` detection fires.

- **Permissions** (verified against Microsoft Learn, graph-rest-1.0
  `organization-get`): application permission `Directory.Read.All` — already
  consented for this app — is explicitly listed as sufficient.
  `Organization.Read.All` would be least-privilege, but no new consent is
  needed or requested.
- **Staleness dedup — one alert per stale episode:** an episode is keyed by
  the `onPremisesLastSyncDateTime` value that went stale. The same value on
  the next poll is the same outage (no re-alert); a healthy poll clears the
  key; a newer value that later goes stale re-alerts. There is deliberately
  no "re-remind every N hours while still stale" option in the MVP.
- **`onPremisesSyncEnabled` not true** (hybrid sync never configured, e.g.
  the dev/test tenant): staleness is not evaluated; a WARN goes to the
  operational log only. On a production sync server that state itself
  deserves investigation.
- **`HEARTBEAT_CHECK_FAILED`:** if the monitor *cannot complete* the Graph
  check (expired client secret, no outbound HTTPS, Graph outage), that is
  itself alerted — staleness is then unverified and there is no backup
  mechanism watching. Deduped to one alert per outage, re-armed by the next
  successful check. This is a deliberate small addition beyond the literal
  spec; strip the `catch` block in the entry script to remove it.

## Outputs

| Output | Where | What |
|---|---|---|
| Catalog log | `logs/syncmonitor-catalog.jsonl` | One JSON line per detection: `TimestampEastern` (America/New_York with correct EST/EDT offset via `[System.TimeZoneInfo]`, never a hardcoded UTC-5), `EventId` (or `STALE_SYNC`/`HEARTBEAT_CHECK_FAILED`), `Meaning`, `Checklist`, `Source` (`EventLog` \| `GraphHeartbeat`), plus `Provider`/`RecordId`/`Level`/`Detail` for events. JSON Lines because it appends without rewriting and each line parses independently. |
| Alert email | Internal SMTP relay | One combined plain-text message per poll (a burst of engine errors = one email, not a storm). Sent with `System.Net.Mail.MailMessage`/`SmtpClient` — `Send-MailMessage` is deprecated in PowerShell 7+. No auth, no TLS (internal relay). |
| Operational log | `logs/syncmonitor-operational.log` | Routine run chatter (poll start/finish, counts, warnings) — separate from the catalog log by design. |
| State | `logs/syncmonitor-state.json` | `LastEventRecordId`, `LastStaleAlertSyncTime` (episode key), `HeartbeatFailureAlerted`, `LastRunUtc`. Deleting it is safe: worst case is one duplicate alert window. |

Everything under `logs/` is gitignored.

## Configuration

`config/syncmonitor-config.psd1` — copy from `syncmonitor-config.psd1.example`
(the real file is gitignored, same convention as the graph-auth module's
`config.psd1`). Format is `.psd1` over JSON deliberately: comments are
supported, `Import-PowerShellDataFile` parses it natively without code
execution, and it matches the repo's existing config convention; the
tradeoff (non-PowerShell tooling can't read it) doesn't apply since only
this monitor consumes it.

| Key | Default | Meaning |
|---|---|---|
| `StalenessThresholdMinutes` | 45 | Tenant-side staleness threshold |
| `PollIntervalMinutes` | 5 | Cadence for the Scheduled Task (informational to the script itself) |
| `EventLog.LogName` | `Application` | Log to poll |
| `EventLog.Providers` | `ADSync`, `Directory Synchronization` | Event sources |
| `EventLog.Levels` | `1, 2` | Critical + Error |
| `EventLog.FirstRunLookbackMinutes` | 60 | First-run scan window (no state yet) |
| `Smtp.Server` / `Smtp.Port` | — | Internal relay host/port |
| `Smtp.From` / `Smtp.To` | — | Sender / recipient list |

TenantId/ClientId and the client secret are **not** in this config — they
come from the graph-auth module's own `config.psd1` defaults and its DPAPI
store, exactly as the export scripts use them.

## Deploying on the sync server

1. Clone the repo; install modules once:
   `Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser`
   (the monitor never auto-installs mid-poll — unattended runs fail loudly
   with instructions instead).
2. Copy `config/syncmonitor-config.psd1.example` →
   `syncmonitor-config.psd1`; set relay + recipients.
3. One interactive first run **as the account the task will run under** to
   seed auth (DPAPI is per-user/per-machine) and confirm a clean pass:
   `pwsh -File sync-monitor/scripts/watch-entra-sync-health.ps1`
   (run `Set-IamScoutGraphDefault -TenantId … -ClientId …` first if that
   user has no graph-auth `config.psd1` yet; the client secret is prompted
   once and DPAPI-stored).
4. Register the Scheduled Task (5-minute repetition, from an elevated
   prompt, adjusting the repo path and `-User`):

   ```powershell
   $action  = New-ScheduledTaskAction -Execute 'pwsh.exe' `
       -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\iam_scout\sync-monitor\scripts\watch-entra-sync-health.ps1"'
   $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
       -RepetitionInterval (New-TimeSpan -Minutes 5)
   Register-ScheduledTask -TaskName 'iam-scout Entra sync health monitor' `
       -Action $action -Trigger $trigger -User 'DOMAIN\svc-syncmonitor' `
       -Password (Read-Host 'Task account password') -RunLevel Limited
   ```

   Exit code 0 = ran (alert or not); 1 = the monitor itself failed (shows as
   Last Run Result in Task Scheduler — worth a periodic glance, since a
   monitor that can't run can't email about it).

## Testing it manually

- **Clean pass:** run the entry script; expect `no issues detected, no alert
  sent`, exit 0, nothing appended to the catalog log.
- **Force the staleness path:** set `StalenessThresholdMinutes = 0` in a
  copy of the config and run with `-ConfigPath <copy>`; any tenant with
  hybrid sync will trip `STALE_SYNC` (one catalog entry + email). Revert.
- **Force the event path:** point `EventLog.Providers` in a config copy at
  a provider with recent errors (e.g. `'Application Error'`) — those IDs are
  unmapped, exercising the fallback entry, catalog log, and email.
- **Reset dedup between experiments:** delete `logs/syncmonitor-state.json`.

### What was validated before shipping (2026-07-13, dev machine + test tenant)

Read-only throughout; no write/create/delete Graph calls.

- Pure-function checks: staleness verdicts (`Healthy`/`Stale`×2/`SyncNotEnabled`),
  ET conversion (July → `-04:00` EDT, January → `-05:00` EST), catalog
  resolution (mapped 611, special `STALE_SYNC`, unmapped → fallback), state
  round-trip.
- Clean pass against the live tenant: app-only connect via stored DPAPI
  secret, ADSync providers absent on the dev machine → warn + skip, tenant
  reports sync not enabled → WARN only, **no alert, exit 0**.
- Forced event path: config copy pointing at `'Application Error'` → 11 real
  events processed as unmapped, 11 catalog JSONL entries with correct ET
  timestamps, one combined email **actually received** by a local SMTP
  listener on `127.0.0.1:2525` (correct envelope, subject, body).
- Dedup: immediate re-run found 0 new events past the persisted RecordId —
  no re-alert, catalog unchanged.
- Not testable off the sync server: a real `ADSync`-source event and a real
  `STALE_SYNC` through Graph (test tenant has no Entra Connect — the
  decision logic was covered by the pure-function tests). Re-verify both
  during deployment using the forced-path steps above.

## Deferred (out of scope for the MVP)

GUI/dashboard/API; AAD Connect Health portal/agent integration; multi-tenant
or multi-server support; historical backfill; re-reminder cadence for
long-running stale episodes; any new Graph permission consent.
