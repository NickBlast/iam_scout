@{
    RootModule        = 'iam-scout-graph-auth.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'edfc4c12-2f9c-4a84-9e65-c60286385221'
    Author            = 'iam_scout'
    Description       = 'Reusable Microsoft Graph app-only auth (cert or client-secret), DPAPI credential store, and required-module check for iam_scout EntraID scripts.'
    PowerShellVersion = '7.0'
    RequiredModules   = @('Microsoft.Graph.Authentication')

    FunctionsToExport = @(
        'Initialize-IamScoutRequiredModule'
        'Connect-IamScoutGraph'
        'Disconnect-IamScoutGraph'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
