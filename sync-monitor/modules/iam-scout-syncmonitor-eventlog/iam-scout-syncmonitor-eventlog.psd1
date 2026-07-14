@{
    RootModule        = 'iam-scout-syncmonitor-eventlog.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '3f7a9c2e-8b41-4d6a-9e15-2c8f0d7b6a01'
    Author            = 'iam_scout'
    Description       = 'Entra Connect sync health monitor: event log polling, error-catalog lookup, staleness evaluation, dedup state, catalog log writer.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-IamScoutSyncEvent'
        'Import-IamScoutSyncCatalog'
        'Resolve-IamScoutSyncCatalogEntry'
        'Test-IamScoutSyncStaleness'
        'Read-IamScoutSyncMonitorState'
        'Save-IamScoutSyncMonitorState'
        'ConvertTo-IamScoutEasternTime'
        'Write-IamScoutSyncCatalogEntry'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
}
