@{
    RootModule        = 'iam-scout-syncmonitor-alerting.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '9d2b5e17-4c8a-4f30-b6d9-7a1e3c0f8b42'
    Author            = 'iam_scout'
    Description       = 'Entra Connect sync health monitor: SMTP alert dispatch via internal unauthenticated relay (System.Net.Mail).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Send-IamScoutSyncAlert')
    CmdletsToExport   = @()
    AliasesToExport   = @()
}
