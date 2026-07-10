#Requires -Version 7.0
<#
================================================================================
 export-entra-app-registrations-v2.ps1

 Same behavior as Export-EntraAppRegistrations.ps1, but Graph app-only
 authentication, the DPAPI client-secret store, and the required-module check
 are delegated to the iam-scout-graph-auth module
 (entra-scripts/modules/iam-scout-graph-auth). This script keeps only the
 Graph data retrieval and Excel export logic.

 HOW TO RUN: same parameters as Export-EntraAppRegistrations.ps1.
   pwsh ./export-entra-app-registrations-v2.ps1 -TenantId <tenant> -ClientId <appId>
================================================================================
#>

[CmdletBinding()]
param(
    # Tenant id (GUID) or verified domain to authenticate against. Required for
    # app-only sign-in.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    # Application (client) id of the app registration used to sign in. Required
    # for app-only sign-in.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ClientId,

    # Folder to write the .xlsx into. Defaults to the current directory.
    [Parameter()]
    [string] $OutputDirectory = (Get-Location).Path,

    # Also retrieve application owners (adds one Graph call per app registration).
    [Parameter()]
    [switch] $IncludeOwners,

    # If a required module is missing, install it (CurrentUser scope) instead of
    # stopping with instructions.
    [Parameter()]
    [switch] $InstallMissingModules,

    # Discard any previously stored client secret and prompt for a new one. Use
    # after the app secret has been rotated.
    [Parameter()]
    [switch] $ResetCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Modules this script depends on (beyond the auth module's own RequiredModules).
# Order matters for import: Authentication first.
$script:RequiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Applications'
    'ImportExcel'
)

# Least-privilege application permission the app registration must be granted
# (with admin consent). App-only tokens already carry this, so it is documentary
# here rather than passed to Connect-MgGraph.
$script:RequiredAppRole = 'Application.Read.All'

Import-Module (Join-Path $PSScriptRoot 'modules/iam-scout-graph-auth/iam-scout-graph-auth.psd1') -Force


#-------------------------------------------------------------------------------
# Get-AppRegistration
#
# Purpose : Retrieve all app registrations and flatten the properties of interest
#           into simple objects suitable for export.
# Params  : -IncludeOwners  When set, makes one Get-MgApplicationOwner call per app
#                           and adds a semicolon-delimited Owners column.
# Returns : An array of PSCustomObjects (one per app registration). Empty array if
#           the tenant has no app registrations. Throws if retrieval fails.
#-------------------------------------------------------------------------------
function Get-AppRegistration {
    [CmdletBinding()]
    param(
        [switch] $IncludeOwners
    )

    # $select the exact fields we export to keep the response small. -All is
    # required because Get-MgApplication returns only the first page by default.
    $selectProperties = @(
        'id'
        'appId'
        'displayName'
        'signInAudience'
        'createdDateTime'
        'publisherDomain'
    )

    try {
        Write-Host "Retrieving app registrations..." -ForegroundColor Cyan
        $applications = Get-MgApplication -All -Property $selectProperties
    }
    catch {
        throw "Failed to retrieve app registrations from Microsoft Graph: $($_.Exception.Message)"
    }

    # Normalize to an array so .Count is reliable for 0/1 result cases.
    $applications = @($applications)
    Write-Host "Found $($applications.Count) app registration(s)." -ForegroundColor Cyan

    if ($applications.Count -eq 0) {
        return @()
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($app in $applications) {
        $index++

        $record = [ordered]@{
            DisplayName     = $app.DisplayName
            AppId           = $app.AppId
            Id              = $app.Id            # object id
            SignInAudience  = $app.SignInAudience
            CreatedDateTime = $app.CreatedDateTime
            PublisherDomain = $app.PublisherDomain
        }

        if ($IncludeOwners) {
            Write-Progress -Activity 'Collecting owners' `
                -Status "$index of $($applications.Count): $($app.DisplayName)" `
                -PercentComplete (($index / $applications.Count) * 100)

            $record['Owners'] = Get-OwnerDisplay -ApplicationId $app.Id
        }

        $records.Add([pscustomobject]$record)
    }

    if ($IncludeOwners) {
        Write-Progress -Activity 'Collecting owners' -Completed
    }

    return $records.ToArray()
}


#-------------------------------------------------------------------------------
# Get-OwnerDisplay
#
# Purpose : Resolve the owners of a single app registration into a readable,
#           semicolon-delimited string. Owner failures are isolated so one bad
#           lookup never aborts the whole export.
# Params  : -ApplicationId  The object id (Id) of the app registration.
# Returns : A string of owner UPNs/display names ('' if none, a marker on error).
#-------------------------------------------------------------------------------
function Get-OwnerDisplay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ApplicationId
    )

    try {
        $owners = @(Get-MgApplicationOwner -ApplicationId $ApplicationId -All)
    }
    catch {
        Write-Warning "Could not retrieve owners for application '$ApplicationId': $($_.Exception.Message)"
        return '<error retrieving owners>'
    }

    if ($owners.Count -eq 0) {
        return ''
    }

    $names = foreach ($owner in $owners) {
        # Owners are directoryObjects; the friendly fields live in AdditionalProperties.
        $props = $owner.AdditionalProperties
        if ($props -and $props['userPrincipalName']) { $props['userPrincipalName'] }
        elseif ($props -and $props['displayName'])   { $props['displayName'] }
        else                                         { $owner.Id }
    }

    return ($names -join '; ')
}


#-------------------------------------------------------------------------------
# Export-AppRegistration
#
# Purpose : Write the collected records to a single timestamped .xlsx file with a
#           named worksheet, auto-sized columns, an auto-filter and a frozen header.
# Params  : -Records          Array of PSCustomObjects to export.
#           -OutputDirectory  Folder to write the workbook into.
# Returns : The full path of the .xlsx file that was written. Throws on failure.
#-------------------------------------------------------------------------------
function Export-AppRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Records,

        [Parameter(Mandatory)]
        [string] $OutputDirectory
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $fileName  = "EntraAppRegistrations_$timestamp.xlsx"
    $fullPath  = Join-Path -Path $OutputDirectory -ChildPath $fileName

    try {
        $Records | Export-Excel `
            -Path $fullPath `
            -WorksheetName 'AppRegistrations' `
            -TableName 'AppRegistrations' `
            -TableStyle 'Medium2' `
            -AutoSize `
            -FreezeTopRow `
            -BoldTopRow
    }
    catch {
        throw "Failed to write Excel file '$fullPath': $($_.Exception.Message)"
    }

    return $fullPath
}


#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
$connected = $false
try {
    Write-Host "Checking required modules..." -ForegroundColor Cyan
    Initialize-IamScoutRequiredModule -ModuleName $script:RequiredModules -InstallMissing:$InstallMissingModules

    # Import only the specific submodules we use (never the full Microsoft.Graph).
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Applications   -ErrorAction Stop
    Import-Module ImportExcel                    -ErrorAction Stop

    Connect-IamScoutGraph -TenantId $TenantId -ClientId $ClientId -ResetCredential:$ResetCredential
    $connected = $true

    $records = Get-AppRegistration -IncludeOwners:$IncludeOwners

    if (@($records).Count -eq 0) {
        Write-Warning "No app registrations found in this tenant. Nothing to export."
    }
    else {
        $outputFile = Export-AppRegistration -Records $records -OutputDirectory $OutputDirectory
        Write-Host "Exported $(@($records).Count) app registration(s) to:" -ForegroundColor Green
        Write-Host "  $outputFile" -ForegroundColor Green
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($connected) {
        Disconnect-IamScoutGraph
    }
}
