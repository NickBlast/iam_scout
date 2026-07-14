#Requires -Version 7.0
<#
================================================================================
 iam-scout-syncmonitor-eventlog

 Detection half of the Entra Connect sync health monitor: Windows event log
 polling (Get-WinEvent), error-catalog lookup, staleness evaluation, the
 monitor's persisted state (dedup high-water marks), the catalog log writer,
 and the America/New_York timestamp conversion. SMTP dispatch lives in the
 sibling iam-scout-syncmonitor-alerting module; Graph auth stays in
 entra-scripts/modules/iam-scout-graph-auth.

 EVENT LOG CMDLET CHOICE (verified in this repo's PS 7 environment):
   Get-WinEvent is used. Get-EventLog is not a real option on PowerShell 7 --
   what ships there is a stub that only exists to say the cmdlet is Windows
   PowerShell 5.1-only. Get-WinEvent also exposes RecordId, which is the
   monotonically increasing per-log sequence number this module uses for
   dedup (a high-water mark survives across polls via the state file).
================================================================================
#>

Set-StrictMode -Version Latest

#-------------------------------------------------------------------------------
# Get-IamScoutSyncEvent
#
# Purpose : Return new (not-yet-processed) events from the given providers in
#           the given log, at the given severity levels.
# Params  : -LogName        Event log to query (Application for ADSync).
#           -Provider       Provider/source names to match (queried one at a
#                            time -- a single missing provider must not sink
#                            the whole query on machines where only one of the
#                            two ADSync sources is registered).
#           -Level          Event levels to include (1=Critical, 2=Error).
#           -StartTime      Oldest event to consider (first-run lookback).
#           -MinRecordId    Dedup floor: only events with RecordId strictly
#                            greater than this are returned. 0 = no floor.
# Returns : Event records sorted by RecordId ascending (possibly empty array).
#-------------------------------------------------------------------------------
function Get-IamScoutSyncEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $LogName,

        [Parameter(Mandatory)]
        [string[]] $Provider,

        [Parameter(Mandatory)]
        [int[]] $Level,

        [Parameter(Mandatory)]
        [datetime] $StartTime,

        [long] $MinRecordId = 0
    )

    $collected = [System.Collections.Generic.List[object]]::new()

    foreach ($providerName in $Provider) {
        $filter = @{
            LogName      = $LogName
            ProviderName = $providerName
            Level        = $Level
            StartTime    = $StartTime
        }

        try {
            $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
            foreach ($e in $events) {
                if ($e.RecordId -gt $MinRecordId) { $collected.Add($e) }
            }
        }
        catch {
            # "No events were found" is a normal healthy result, not an error.
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { continue }

            # A provider that is not registered on this machine (e.g. only one
            # of the two ADSync source names exists) is expected -- warn once
            # per run and keep going with the other providers.
            if ($_.Exception.Message -match 'not an event provider|could not be found|does not exist') {
                Write-Warning "Event provider '$providerName' not found on this machine -- skipping it this poll."
                continue
            }

            throw "Failed to query event log '$LogName' for provider '$providerName': $($_.Exception.Message)"
        }
    }

    # The leading comma keeps an empty result an actual array through pipeline
    # unrolling -- otherwise callers get $null and .Count breaks under
    # Set-StrictMode.
    return , @($collected | Sort-Object RecordId)
}


#-------------------------------------------------------------------------------
# Import-IamScoutSyncCatalog
#
# Purpose : Load the editable error catalog (JSON) mapping event IDs to a
#           human-readable meaning and a remediation checklist.
# Returns : The parsed catalog object. Throws if the file is missing or
#           malformed -- an unreadable catalog is a deployment error, and the
#           monitor must not silently run without its mappings.
#-------------------------------------------------------------------------------
function Import-IamScoutSyncCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Error catalog not found at '$Path'."
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Error catalog at '$Path' is not valid JSON: $($_.Exception.Message)"
    }
}


#-------------------------------------------------------------------------------
# Resolve-IamScoutSyncCatalogEntry
#
# Purpose : Map an event ID (or a special key like STALE_SYNC) to its catalog
#           meaning + checklist. Unknown IDs resolve to the catalog's
#           'unmapped' fallback entry -- they are never dropped.
# Returns : @{ Key; Meaning; Checklist (string[]); Mapped (bool) }
#-------------------------------------------------------------------------------
function Resolve-IamScoutSyncCatalogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Catalog,

        [Parameter(Mandatory)]
        [string] $Key
    )

    $entry = $null
    $mapped = $false

    if ($Catalog.events.PSObject.Properties.Name -contains $Key) {
        $entry  = $Catalog.events.$Key
        $mapped = $true
    }
    elseif ($Catalog.special.PSObject.Properties.Name -contains $Key) {
        $entry  = $Catalog.special.$Key
        $mapped = $true
    }
    else {
        $entry = $Catalog.unmapped
    }

    return @{
        Key       = $Key
        Meaning   = [string] $entry.meaning
        Checklist = @($entry.checklist | ForEach-Object { [string] $_ })
        Mapped    = $mapped
    }
}


#-------------------------------------------------------------------------------
# Test-IamScoutSyncStaleness
#
# Purpose : Pure decision function for the Graph heartbeat: given what the
#           tenant reports, is sync stale? Kept side-effect free so the logic
#           can be exercised directly in tests without a hybrid tenant.
# Params  : -OnPremisesSyncEnabled      Tenant's onPremisesSyncEnabled ($null
#                                        when hybrid sync was never set up).
#           -OnPremisesLastSyncDateTime Tenant's last successful sync (UTC),
#                                        $null if never synced.
#           -ThresholdMinutes           Staleness threshold.
#           -NowUtc                     Injectable clock (defaults to now).
# Returns : @{ Status = 'Stale'|'Healthy'|'SyncNotEnabled'; AgeMinutes; Detail }
#-------------------------------------------------------------------------------
function Test-IamScoutSyncStaleness {
    [CmdletBinding()]
    param(
        [nullable[bool]] $OnPremisesSyncEnabled,

        [nullable[datetime]] $OnPremisesLastSyncDateTime,

        [Parameter(Mandatory)]
        [int] $ThresholdMinutes,

        [datetime] $NowUtc = [datetime]::UtcNow
    )

    if ($OnPremisesSyncEnabled -ne $true) {
        return @{
            Status     = 'SyncNotEnabled'
            AgeMinutes = $null
            Detail     = "Tenant reports onPremisesSyncEnabled = '$OnPremisesSyncEnabled' -- no hybrid sync heartbeat to evaluate."
        }
    }

    if ($null -eq $OnPremisesLastSyncDateTime) {
        return @{
            Status     = 'Stale'
            AgeMinutes = $null
            Detail     = 'Tenant reports sync enabled but no onPremisesLastSyncDateTime at all -- no successful sync has ever been recorded.'
        }
    }

    $age = ($NowUtc - $OnPremisesLastSyncDateTime.ToUniversalTime()).TotalMinutes
    if ($age -gt $ThresholdMinutes) {
        return @{
            Status     = 'Stale'
            AgeMinutes = [math]::Round($age, 1)
            Detail     = "Last successful sync was $([math]::Round($age, 1)) minutes ago (threshold: $ThresholdMinutes)."
        }
    }

    return @{
        Status     = 'Healthy'
        AgeMinutes = [math]::Round($age, 1)
        Detail     = "Last successful sync was $([math]::Round($age, 1)) minutes ago (threshold: $ThresholdMinutes)."
    }
}


#-------------------------------------------------------------------------------
# Read-IamScoutSyncMonitorState / Save-IamScoutSyncMonitorState
#
# Purpose : Persist the monitor's dedup state between scheduled-task runs:
#             LastEventRecordId       -- event log high-water mark
#             LastStaleAlertSyncTime  -- the onPremisesLastSyncDateTime value a
#                                        STALE_SYNC alert was already sent for
#                                        (one alert per stale episode; a new
#                                        lastSync value re-arms the alert)
#             HeartbeatFailureAlerted -- HEARTBEAT_CHECK_FAILED already sent
#                                        (re-armed by the next successful check)
# Returns : Read- returns a hashtable with defaults when no state file exists
#           (first run) or the file is unreadable (fail open: worst case is a
#           duplicate alert, never a missed one).
#-------------------------------------------------------------------------------
function Read-IamScoutSyncMonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $default = @{
        LastEventRecordId       = [long] 0
        LastStaleAlertSyncTime  = $null
        HeartbeatFailureAlerted = $false
    }

    if (-not (Test-Path -LiteralPath $Path)) { return $default }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

        # ConvertFrom-Json re-hydrates ISO timestamps as [datetime]; the stale
        # episode key must stay the exact string it was saved as (round-trip
        # 'o' format, UTC) or the string equality dedup check breaks.
        $staleKey = $raw.LastStaleAlertSyncTime
        if ($staleKey -is [datetime]) {
            $staleKey = $staleKey.ToUniversalTime().ToString('o')
        }

        return @{
            LastEventRecordId       = [long] $raw.LastEventRecordId
            LastStaleAlertSyncTime  = $staleKey
            HeartbeatFailureAlerted = [bool] $raw.HeartbeatFailureAlerted
        }
    }
    catch {
        Write-Warning "State file '$Path' is unreadable ($($_.Exception.Message)) -- starting from defaults; a duplicate alert is possible this run."
        return $default
    }
}

function Save-IamScoutSyncMonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $State['LastRunUtc'] = [datetime]::UtcNow.ToString('o')
    $State | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding utf8
}


#-------------------------------------------------------------------------------
# ConvertTo-IamScoutEasternTime
#
# Purpose : Convert a timestamp to America/New_York wall-clock time with the
#           correct EST/EDT offset for that instant, via [System.TimeZoneInfo]
#           (never a hardcoded UTC-5). On Windows the canonical zone id is
#           'Eastern Standard Time'; modern .NET also accepts the IANA id
#           'America/New_York', so both are tried.
# Returns : ISO-8601 string with offset, e.g. '2026-07-13T09:15:00-04:00'.
#-------------------------------------------------------------------------------
function ConvertTo-IamScoutEasternTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime] $DateTime
    )

    if (-not (Get-Variable -Name IamScoutEasternZone -Scope Script -ErrorAction SilentlyContinue)) {
        $script:IamScoutEasternZone = $null
        foreach ($zoneId in @('America/New_York', 'Eastern Standard Time')) {
            try {
                $script:IamScoutEasternZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($zoneId)
                break
            }
            catch [System.TimeZoneNotFoundException] { continue }
        }
        if (-not $script:IamScoutEasternZone) {
            throw "Neither 'America/New_York' nor 'Eastern Standard Time' resolves to a time zone on this machine."
        }
    }

    $utc     = $DateTime.ToUniversalTime()
    $eastern = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $script:IamScoutEasternZone)
    $offset  = $script:IamScoutEasternZone.GetUtcOffset($utc)
    $sign    = if ($offset -lt [timespan]::Zero) { '-' } else { '+' }

    return ('{0:yyyy-MM-ddTHH:mm:ss}{1}{2:hh\:mm}' -f $eastern, $sign, $offset.Duration())
}


#-------------------------------------------------------------------------------
# Write-IamScoutSyncCatalogEntry
#
# Purpose : Append one structured detection to the catalog log as a single
#           JSON line (JSON Lines format: appendable without rewriting the
#           file, and each line parses independently).
# Params  : -Entry  Hashtable with at least: TimestampEastern, EventId,
#                   Meaning, Checklist, Source ('EventLog'|'GraphHeartbeat').
#-------------------------------------------------------------------------------
function Write-IamScoutSyncCatalogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Entry,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $line = $Entry | ConvertTo-Json -Compress -Depth 5
    Add-Content -LiteralPath $Path -Value $line -Encoding utf8
}


Export-ModuleMember -Function @(
    'Get-IamScoutSyncEvent'
    'Import-IamScoutSyncCatalog'
    'Resolve-IamScoutSyncCatalogEntry'
    'Test-IamScoutSyncStaleness'
    'Read-IamScoutSyncMonitorState'
    'Save-IamScoutSyncMonitorState'
    'ConvertTo-IamScoutEasternTime'
    'Write-IamScoutSyncCatalogEntry'
)
