#Requires -Version 7.0
<#
================================================================================
 watch-entra-sync-health.ps1 -- Entra Connect sync health monitor (entry point)

 Single-shot poll intended to be run every PollIntervalMinutes by a Windows
 Scheduled Task on the on-prem Entra Connect sync server. Two independent
 detections per run:

   1. EVENT LOG  -- new Critical/Error events from the ADSync engine sources
      in the Application log since the last processed RecordId.
   2. GRAPH HEARTBEAT -- the tenant's onPremisesLastSyncDateTime
      (Get-MgOrganization, app-only via Connect-IamScoutGraph) older than the
      configured staleness threshold. Runs even when the local engine logs
      nothing -- the whole point is independence from local self-reporting.

 On any detection: append a structured entry to the catalog log (JSON Lines)
 and send one combined plain-text email via the internal SMTP relay. Routine
 run chatter goes to a separate operational log.

 GRAPH PERMISSIONS (verified against Microsoft Learn, graph-rest-1.0
 organization-get): application permissions Organization.Read.All or
 Directory.Read.All both satisfy GET /organization. This monitor relies on
 the already-consented Directory.Read.All -- no new consent required.

 Exit codes: 0 = ran to completion (alerts or not), 1 = the monitor itself
 failed (visible as Last Run Result in Task Scheduler).
================================================================================
#>
[CmdletBinding()]
param(
    # Path to the monitor config. Default: ../config/syncmonitor-config.psd1
    # (the git-ignored copy of syncmonitor-config.psd1.example).
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'syncmonitor-config.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SyncMonitorRoot = Split-Path -Path $PSScriptRoot -Parent
$script:RepoRoot        = Split-Path -Path $script:SyncMonitorRoot -Parent
$script:LogDir          = Join-Path $script:SyncMonitorRoot 'logs'
$script:CatalogLogPath  = Join-Path $script:LogDir 'syncmonitor-catalog.jsonl'
$script:OperationalLog  = Join-Path $script:LogDir 'syncmonitor-operational.log'
$script:StatePath       = Join-Path $script:LogDir 'syncmonitor-state.json'
$script:CatalogPath     = Join-Path $script:SyncMonitorRoot 'config' 'error-catalog.json'

Import-Module (Join-Path $script:SyncMonitorRoot 'modules' 'iam-scout-syncmonitor-eventlog' 'iam-scout-syncmonitor-eventlog.psd1') -Force
Import-Module (Join-Path $script:SyncMonitorRoot 'modules' 'iam-scout-syncmonitor-alerting' 'iam-scout-syncmonitor-alerting.psd1') -Force


#-------------------------------------------------------------------------------
# Write-OperationalLog -- routine (non-catalog) run logging: timestamped line
# to logs/syncmonitor-operational.log plus console echo for manual runs.
#-------------------------------------------------------------------------------
function Write-OperationalLog {
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO'
    )

    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }

    $line = '{0:o} [{1}] {2}' -f [datetime]::UtcNow, $Level, $Message
    Add-Content -LiteralPath $script:OperationalLog -Value $line -Encoding utf8

    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}


#-------------------------------------------------------------------------------
# Format-AlertBody -- one plain-text block per detection for the email body.
#-------------------------------------------------------------------------------
function Format-AlertBody {
    param(
        [Parameter(Mandatory)]
        [array] $Entries
    )

    $blocks = foreach ($entry in $Entries) {
        $checklist = ($entry.Checklist | ForEach-Object { "    - $_" }) -join "`n"
        @"
[$($entry.EventId)] $($entry.Meaning)
  When (America/New_York): $($entry.TimestampEastern)
  Source: $($entry.Source)
  Detail: $($entry.Detail)
  What to check:
$checklist
"@
    }

    return @"
Entra Connect sync health monitor on $env:COMPUTERNAME detected $($Entries.Count) issue(s).

$($blocks -join "`n")
Catalog log: $script:CatalogLogPath
"@
}


function Main {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config not found at '$ConfigPath'. Copy syncmonitor-config.psd1.example to syncmonitor-config.psd1 and edit it."
    }
    $config  = Import-PowerShellDataFile -LiteralPath $ConfigPath
    $catalog = Import-IamScoutSyncCatalog -Path $script:CatalogPath
    $state   = Read-IamScoutSyncMonitorState -Path $script:StatePath

    Write-OperationalLog "Poll started (config: $ConfigPath; last RecordId: $($state.LastEventRecordId))."

    # Detections accumulate here; one combined email is sent at the end so a
    # burst of engine errors produces one message per poll, not a mail storm.
    $alertEntries = [System.Collections.Generic.List[hashtable]]::new()

    #---------------------------------------------------------------------------
    # Detection 1: local sync engine errors in the Application event log
    #---------------------------------------------------------------------------
    $isFirstRun = ($state.LastEventRecordId -eq 0)
    $startTime  = if ($isFirstRun) {
        (Get-Date).AddMinutes(-1 * [int] $config.EventLog.FirstRunLookbackMinutes)
    }
    else {
        # RecordId is the real dedup floor; StartTime just bounds the query.
        (Get-Date).AddDays(-7)
    }

    $events = Get-IamScoutSyncEvent `
        -LogName $config.EventLog.LogName `
        -Provider $config.EventLog.Providers `
        -Level $config.EventLog.Levels `
        -StartTime $startTime `
        -MinRecordId $state.LastEventRecordId

    Write-OperationalLog "Event log check: $($events.Count) new event(s) from providers [$($config.EventLog.Providers -join ', ')]."

    foreach ($event in $events) {
        $resolved = Resolve-IamScoutSyncCatalogEntry -Catalog $catalog -Key ([string] $event.Id)
        $entry = @{
            TimestampEastern = ConvertTo-IamScoutEasternTime -DateTime $event.TimeCreated
            EventId          = [string] $event.Id
            Meaning          = $resolved.Meaning
            Checklist        = $resolved.Checklist
            Source           = 'EventLog'
            Provider         = $event.ProviderName
            RecordId         = $event.RecordId
            Level            = $event.LevelDisplayName
            Detail           = ($event.Message ?? '').Split("`n")[0].Trim()
            Mapped           = $resolved.Mapped
        }
        Write-IamScoutSyncCatalogEntry -Entry $entry -Path $script:CatalogLogPath
        $alertEntries.Add($entry)
        if ($event.RecordId -gt $state.LastEventRecordId) {
            $state.LastEventRecordId = [long] $event.RecordId
        }
    }

    #---------------------------------------------------------------------------
    # Detection 2: tenant-side sync staleness via Microsoft Graph
    #---------------------------------------------------------------------------
    try {
        # The auth module's manifest requires Microsoft.Graph.Authentication;
        # this monitor runs unattended, so a missing module is a hard error
        # with install instructions -- never an auto-install mid-poll.
        foreach ($module in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.DirectoryManagement')) {
            if (-not (Get-Module -ListAvailable -Name $module)) {
                throw "Missing required module '$module'. Install it once with: Install-Module $module -Scope CurrentUser"
            }
        }
        Import-Module (Join-Path $script:RepoRoot 'entra-scripts' 'modules' 'iam-scout-graph-auth' 'iam-scout-graph-auth.psd1') -Force
        Import-Module Microsoft.Graph.Identity.DirectoryManagement

        # TenantId/ClientId come from the graph-auth module's own config.psd1
        # defaults; the client secret comes from its DPAPI store. First-time
        # setup on a new server is interactive (see design doc) -- after that
        # this is fully silent.
        Connect-IamScoutGraph

        $org = Get-MgOrganization -Property 'id,displayName,onPremisesSyncEnabled,onPremisesLastSyncDateTime' |
            Select-Object -First 1
        if (-not $org) { throw 'Get-MgOrganization returned no organization object.' }

        $verdict = Test-IamScoutSyncStaleness `
            -OnPremisesSyncEnabled $org.OnPremisesSyncEnabled `
            -OnPremisesLastSyncDateTime $org.OnPremisesLastSyncDateTime `
            -ThresholdMinutes ([int] $config.StalenessThresholdMinutes)

        Write-OperationalLog "Graph heartbeat: $($verdict.Status). $($verdict.Detail)"

        switch ($verdict.Status) {
            'Stale' {
                # One alert per stale episode: the episode is identified by the
                # lastSync value that went stale. Same value next poll = same
                # episode = no re-alert; a newer value that later goes stale
                # re-arms this.
                $episodeKey = if ($org.OnPremisesLastSyncDateTime) { $org.OnPremisesLastSyncDateTime.ToUniversalTime().ToString('o') } else { 'never-synced' }
                if ($state.LastStaleAlertSyncTime -eq $episodeKey) {
                    Write-OperationalLog "STALE_SYNC already alerted for episode '$episodeKey' -- suppressing duplicate."
                }
                else {
                    $resolved = Resolve-IamScoutSyncCatalogEntry -Catalog $catalog -Key 'STALE_SYNC'
                    $entry = @{
                        TimestampEastern = ConvertTo-IamScoutEasternTime -DateTime (Get-Date)
                        EventId          = 'STALE_SYNC'
                        Meaning          = $resolved.Meaning
                        Checklist        = $resolved.Checklist
                        Source           = 'GraphHeartbeat'
                        Detail           = "$($verdict.Detail) Tenant: $($org.DisplayName)."
                        Mapped           = $true
                    }
                    Write-IamScoutSyncCatalogEntry -Entry $entry -Path $script:CatalogLogPath
                    $alertEntries.Add($entry)
                    $state.LastStaleAlertSyncTime = $episodeKey
                }
            }
            'Healthy' {
                # Healthy heartbeat closes any stale episode.
                $state.LastStaleAlertSyncTime = $null
            }
            'SyncNotEnabled' {
                Write-OperationalLog "Tenant reports on-premises sync not enabled -- staleness not evaluated. On a production sync server this deserves investigation." -Level WARN
            }
        }

        $state.HeartbeatFailureAlerted = $false
    }
    catch {
        # The monitor failing to *check* is itself alert-worthy (staleness is
        # unverified and there is no backup mechanism), but only once per
        # outage -- re-armed by the next successful check above.
        Write-OperationalLog "Graph heartbeat check failed: $($_.Exception.Message)" -Level ERROR
        if (-not $state.HeartbeatFailureAlerted) {
            $resolved = Resolve-IamScoutSyncCatalogEntry -Catalog $catalog -Key 'HEARTBEAT_CHECK_FAILED'
            $entry = @{
                TimestampEastern = ConvertTo-IamScoutEasternTime -DateTime (Get-Date)
                EventId          = 'HEARTBEAT_CHECK_FAILED'
                Meaning          = $resolved.Meaning
                Checklist        = $resolved.Checklist
                Source           = 'GraphHeartbeat'
                Detail           = $_.Exception.Message
                Mapped           = $true
            }
            Write-IamScoutSyncCatalogEntry -Entry $entry -Path $script:CatalogLogPath
            $alertEntries.Add($entry)
            $state.HeartbeatFailureAlerted = $true
        }
    }

    #---------------------------------------------------------------------------
    # Alerting + state persistence. State is saved BEFORE the email attempt:
    # if the relay is down we prefer a lost email over re-alert loops forever,
    # and the failed send is captured in the operational log and exit code.
    #---------------------------------------------------------------------------
    Save-IamScoutSyncMonitorState -State $state -Path $script:StatePath

    if ($alertEntries.Count -eq 0) {
        Write-OperationalLog 'Poll finished: no issues detected, no alert sent.'
        return
    }

    $subject = '[iam-scout] Entra Connect sync ALERT -- {0} issue(s) on {1}' -f $alertEntries.Count, $env:COMPUTERNAME
    Send-IamScoutSyncAlert `
        -SmtpServer $config.Smtp.Server `
        -Port ([int] $config.Smtp.Port) `
        -From $config.Smtp.From `
        -To ([string[]] $config.Smtp.To) `
        -Subject $subject `
        -Body (Format-AlertBody -Entries $alertEntries.ToArray())

    Write-OperationalLog "Poll finished: $($alertEntries.Count) issue(s) logged to catalog and alert email sent to $($config.Smtp.To -join ', ')."
}


try {
    Main
    exit 0
}
catch {
    try { Write-OperationalLog "Monitor run failed: $($_.Exception.Message)" -Level ERROR } catch {}
    Write-Error $_
    exit 1
}
