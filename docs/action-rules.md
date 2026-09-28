# CLI Action Rules

Architecture rules for the **CLI front-end** sub-project: an interactive
menu (`cli/`) that runs the existing `entra-scripts/` exports. This spec is
**finalized**. Implement it as written. If a rule turns out to be wrong in
practice, log it in `docs/LEARNINGS.md` and propose a change. Don't quietly
work around it.

> Status (2026-09-28): spec only. `cli/` does not exist yet. It will be
> built in a separate pass.

---

## Folder layout

```
cli/
  start-iam-scout.ps1        # launcher: builds $Context, discovers actions, runs the menu loop
  core/
    menu.ps1                 # menu rendering + selection
    prompts.ps1              # input helpers (e.g. Read-CliInput)
    registry.ps1             # action discovery + contract validation
  actions/
    10-export-app-registrations.ps1
    20-map-service-principals.ps1
  tests/                     # Pester tests (seams only — see rule 6)
```

## Dependency rules (one-way)

```
start-iam-scout.ps1 ──► core/ ◄── actions/ ──► entra-scripts/
```

| From | May reference | Must never reference |
|---|---|---|
| `actions/` | `core/` helpers, `entra-scripts/` | another action |
| `core/` | nothing action-specific | any specific action (by name, Id, or file) |
| `entra-scripts/` | its own modules | anything under `cli/` |

Consequences:
- **Actions never call each other.** If two actions need the same logic,
  put it in `core/` (if it's CLI plumbing) or `entra-scripts/` (if it's
  Graph/export logic).
- **`entra-scripts/` stays runnable standalone.** Every script must keep
  working from a plain `pwsh ./entra-scripts/<script>.ps1 ...` invocation
  with no knowledge that a menu exists.

## Registration: auto-discovery

At startup the launcher scans `cli/actions/*.ps1`. Each file **returns one
definition hashtable** as its output (the file is a data file, not a script
that registers itself). The registry validates each definition and builds
the menu from the valid ones.

Adding an action means adding a file. There is no shared registry file, list, or
switch statement to edit.

## Execution: in-process

Actions invoke `entra-scripts/` scripts **in-process** with the call
operator:

```powershell
& $scriptPath @params
```

They do not spawn a child `pwsh` process.

> **Confirm before assuming:** check how the existing auth module handles
> an already-open Graph connection before you assume it persists across a
> menu session. Observations from the 2026-09-28 audit (re-verify against
> the code when implementing):
> - `Connect-IamScoutGraph` always calls `Connect-MgGraph`. It does not check
>   for or reuse an existing context.
> - Both module-based scripts (`export-entra-app-registrations-v2.ps1`,
>   `export-entra-identity-inventory.ps1`) call `Disconnect-IamScoutGraph`
>   in their top-level `finally`. So **the connection does not persist
>   between actions**. Each action reconnects, which is silent after the
>   first DPAPI-stored secret.
> - Both scripts run `Import-Module ... -Force` on the auth module every
>   invocation, which reloads its `$script:` defaults.
> - Both scripts use `exit 1` on failure. Inside a script invoked with `&`,
>   `exit` ends that script and sets `$LASTEXITCODE`. It does not end the
>   launcher, but the action must check `$LASTEXITCODE` (or `$?`) to report
>   failure, because no exception reaches its `try/catch`.
> - Both scripts set `Set-StrictMode` / `$ErrorActionPreference` at their
>   own script scope. With `&` (not dot-sourcing), those settings stay
>   inside the script's scope and don't leak back into the launcher.

## Containment rules

1. **Adding an action = adding a file.** Never edit a shared list.
2. **Actions are thin.** An action file holds metadata plus a call into
   `entra-scripts/`. It contains no Graph logic (no `Get-Mg*`, no
   `Connect-*`, no data shaping). If an action needs logic that doesn't
   exist yet, add it to `entra-scripts/` first.
3. **State travels in one `$Context` object**, built once by the launcher
   and passed to every action's `Run` block. Actions share nothing through
   `$global:`. An action never mutates state that another action depends on.
4. **`core/` files contain only function definitions.** No
   `$ErrorActionPreference`, `Set-StrictMode`, `$ProgressPreference`, or
   any other file-scope preference statement. Those leak into every script
   that runs afterward, including every `entra-scripts/` call.
5. **Failures are contained at two points:**
   - *Load time:* an action whose definition lacks a required field is
     **skipped with a warning**. The menu still starts with the remaining
     actions.
   - *Execution time:* each action's `Run` body executes inside
     `try/catch`. On error the launcher reports it and **returns to the
     menu**. It never exits the session.
6. **Pester tests cover the seams only:**
   - contract validation: required fields present, invalid definitions
     rejected
   - unique `Id`s across all discovered actions
   - a clean launcher start with an **empty** `actions/` folder

   Tests make **no live Graph calls**.

## Action contract

Illustrative. The field set is the contract; the body is an example.

```powershell
# cli/actions/10-export-app-registrations.ps1
@{
    Id    = 'export-app-registrations'
    Title = 'Export app registrations'
    Run   = {
        param($Context)
        $out = Read-CliInput -Label 'Output folder' -Default $Context.DefaultOutputPath
        & (Join-Path $Context.RepoRoot 'entra-scripts\<script>.ps1') -OutputPath $out
    }
}
```

| Field | Type | Purpose |
|---|---|---|
| `Id` | string | Stable identifier for logs, docs, and tests. Unique. Never changes once published. |
| `Title` | string | Menu display text. Free to change. |
| `Run` | scriptblock | `param($Context)`. The action body. Runs inside the launcher's `try/catch`. |

**Ordering vs. identity:** the filename prefix (`10-`, `20-`, ...) sets menu
order. Leave gaps so you can insert actions without renaming. `Id` is the
stable identifier. Never use the display position (menu number) as an
identifier in logs, docs, or tests.

## Notes for the implementation pass

These are open items found during the 2026-09-28 audit. They don't change
the spec above.

- The illustrative contract passes `-OutputPath`. The existing scripts
  expose **`-OutputDirectory`**. Use the real parameter name.
- `export-entra-app-registrations-v2.ps1` declares `-TenantId`/`-ClientId`
  as **Mandatory**. `export-entra-identity-inventory.ps1` makes them
  optional (falls back to `config.psd1` defaults). An action calling v2
  must pass both, for example from `$Context`.
- There is no standalone service-principal mapping script. SP inventory is
  currently inside `export-entra-app-registrations-v2.ps1` (Phase 2
  sheets). Decide which script `20-map-service-principals` wraps before
  building it.
