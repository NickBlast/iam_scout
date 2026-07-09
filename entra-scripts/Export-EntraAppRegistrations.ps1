#Requires -Version 7.0
<#
================================================================================
 Export-EntraAppRegistrations.ps1

 Connects to Microsoft Graph (Entra ID) with an APP-ONLY (service principal /
 client-credentials) sign-in and exports every APP REGISTRATION (the
 `application` resource -- NOT enterprise apps / service principals) to a single
 timestamped .xlsx file.

 --------------------------------------------------------------------------------
 REQUIRED MODULES (installed from the PowerShell Gallery, CurrentUser scope):
   - Microsoft.Graph.Authentication   (Connect-MgGraph / Disconnect-MgGraph)
   - Microsoft.Graph.Applications     (Get-MgApplication / Get-MgApplicationOwner)
   - ImportExcel                      (Export-Excel -- no Excel install needed)

   The full 'Microsoft.Graph' meta-module is intentionally NOT used; only the two
   submodules above are imported so load time stays small.

 REQUIRED GRAPH PERMISSION (APPLICATION, least privilege):
   - Application.Read.All   granted as an APPLICATION permission on the app
                            registration, WITH ADMIN CONSENT (not delegated).
                            The script never writes to Graph. App-only tokens
                            carry the app's granted application permissions, so
                            Connect-MgGraph is called WITHOUT -Scopes.

 AUTHENTICATION (app-only / client credentials):
   Requires three values: -TenantId, -ClientId, and a client secret. The secret
   is NEVER passed as a parameter or hardcoded -- it is captured once via a
   secure prompt and then persisted so later runs authenticate silently.

 CLIENT-SECRET STORAGE -- DESIGN & TRADE-OFFS:
   The secret is stored as a DPAPI-encrypted SecureString using ONLY built-in
   PowerShell/Windows capability (ConvertFrom-SecureString / ConvertTo-SecureString
   with no -Key). Verified against Microsoft Learn: "If no key is specified, the
   Windows Data Protection API (DPAPI) is used to encrypt the standard string."
   The ciphertext is written to a per-user file under %LOCALAPPDATA%, namespaced
   by tenant + client id so different apps never collide.

   Why this over cmdkey.exe / Windows Credential Manager:
     - It is a fully supported, self-contained round-trip in PowerShell. cmdkey.exe
       can WRITE a generic credential but PowerShell has no built-in cmdlet to READ
       the password back -- that requires P/Invoke to the CredRead Win32 API, which
       is more code and more fragile. ConvertTo/From-SecureString is idiomatic and
       needs no extra modules.
   Trade-off:
     - DPAPI (CurrentUser scope) binds the ciphertext to THIS Windows user on THIS
       machine. Another user, or the same file copied to another machine, cannot
       decrypt it and will be re-prompted. That non-portability is a security
       feature (the secret at rest is useless if exfiltrated) but means the store
       is not shareable across users/machines.
   The plaintext secret is never written to console output, logs, or transcripts.

 HOW TO RUN:
   # First run prompts for the secret and stores it; later runs are silent:
   pwsh ./Export-EntraAppRegistrations.ps1 -TenantId <tenant> -ClientId <appId>

   # Choose an output folder:
   pwsh ./Export-EntraAppRegistrations.ps1 -TenantId <tenant> -ClientId <appId> -OutputDirectory C:\Reports

   # Also collect owners (one extra Graph call per app -- slower on big tenants):
   pwsh ./Export-EntraAppRegistrations.ps1 -TenantId <tenant> -ClientId <appId> -IncludeOwners

   # Auto-install any missing modules instead of stopping with instructions:
   pwsh ./Export-EntraAppRegistrations.ps1 -TenantId <tenant> -ClientId <appId> -InstallMissingModules

   # Discard the stored secret and prompt for a new one (e.g. after rotation):
   pwsh ./Export-EntraAppRegistrations.ps1 -TenantId <tenant> -ClientId <appId> -ResetCredential

 NOTES / VERIFIED AGAINST MICROSOFT LEARN (graph-powershell-1.0):
   - Get-MgApplication does NOT auto-paginate; -All is required for full results.
   - App-only sign-in uses -ClientSecretCredential with a PSCredential whose
     UserName is the client (app) id and whose password is the secret.
   - Get-MgContext.AuthType returns 'AppOnly' for a successful client-credentials
     connection.
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

# Modules this script depends on. Order matters for import: Authentication first.
$script:RequiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Applications'
    'ImportExcel'
)

# Least-privilege application permission the app registration must be granted
# (with admin consent). App-only tokens already carry this, so it is documentary
# here rather than passed to Connect-MgGraph.
$script:RequiredAppRole = 'Application.Read.All'


#-------------------------------------------------------------------------------
# Initialize-RequiredModule
#
# Purpose : Ensure every module in $script:RequiredModules is available, then
#           import the Graph submodules so the meta-module is never loaded.
# Params  : -InstallMissing  When set, missing modules are installed from the
#                            PowerShell Gallery (CurrentUser scope). When not set,
#                            the function reports what to install and throws.
# Returns : Nothing. Throws if a module is missing (and not installed) or if an
#           install fails.
#-------------------------------------------------------------------------------
function Initialize-RequiredModule {
    [CmdletBinding()]
    param(
        [switch] $InstallMissing
    )

    $missing = @()

    foreach ($module in $script:RequiredModules) {
        if (Get-Module -ListAvailable -Name $module) {
            Write-Host "  [ok]      $module is installed." -ForegroundColor DarkGray
            continue
        }

        if ($InstallMissing) {
            Write-Host "  [install] $module not found -- installing (CurrentUser)..." -ForegroundColor Yellow
            try {
                Install-Module -Name $module -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
            }
            catch {
                throw "Failed to install required module '$module': $($_.Exception.Message)"
            }
        }
        else {
            $missing += $module
        }
    }

    if ($missing.Count -gt 0) {
        $installLine = "Install-Module {0} -Scope CurrentUser" -f ($missing -join ', ')
        throw @"
Missing required module(s): $($missing -join ', ')

Install them and re-run, for example:
    $installLine

Or re-run this script with -InstallMissingModules to install them automatically.
"@
    }

    # Import only the specific submodules we use (never the full Microsoft.Graph).
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Applications   -ErrorAction Stop
    Import-Module ImportExcel                    -ErrorAction Stop
}


#-------------------------------------------------------------------------------
# Get-SecretStorePath
#
# Purpose : Return the per-user file path where this tenant+app's DPAPI-encrypted
#           client secret is (or will be) stored. The directory is created if it
#           does not yet exist.
# Params  : -TenantId / -ClientId  Used to namespace the file so secrets for
#                                  different apps never collide.
# Returns : A full file path (string). The file itself may or may not exist yet.
#-------------------------------------------------------------------------------
function Get-SecretStorePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $ClientId
    )

    $storeDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'EntraAppExport'
    if (-not (Test-Path -LiteralPath $storeDir)) {
        New-Item -ItemType Directory -Path $storeDir -Force | Out-Null
    }

    # Hash tenant|client into an opaque, filesystem-safe token so the filename
    # neither leaks identifiers nor breaks on unexpected characters.
    $key    = ("{0}|{1}" -f $TenantId, $ClientId).ToLowerInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))
    }
    finally {
        $sha256.Dispose()
    }
    $token = [System.BitConverter]::ToString($hashBytes).Replace('-', '')

    return (Join-Path -Path $storeDir -ChildPath ("secret_$token.dpapi"))
}


#-------------------------------------------------------------------------------
# Save-ClientSecret
#
# Purpose : Persist a client secret to disk as a DPAPI-encrypted string. With no
#           -Key, ConvertFrom-SecureString encrypts via the Windows Data Protection
#           API bound to the current user + machine (verified on Microsoft Learn).
#           Only ciphertext is written; the plaintext secret never leaves memory.
# Params  : -SecureSecret  The secret as a SecureString.
#           -Path          Destination file (see Get-SecretStorePath).
# Returns : Nothing. Throws on write failure.
#-------------------------------------------------------------------------------
function Save-ClientSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [securestring] $SecureSecret,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $encrypted = ConvertFrom-SecureString -SecureString $SecureSecret
    # -NoNewline keeps the file to exactly the ciphertext; ASCII is safe because
    # DPAPI output is a hex string.
    Set-Content -LiteralPath $Path -Value $encrypted -Encoding ascii -NoNewline
}


#-------------------------------------------------------------------------------
# Read-StoredClientSecret
#
# Purpose : Reconstruct a previously stored client secret. ConvertTo-SecureString
#           with no -Key reverses the DPAPI encryption for the same user/machine.
# Params  : -Path  The store file to read.
# Returns : A SecureString, or $null if no (usable) stored secret exists. Throws a
#           helpful message if a file exists but cannot be decrypted (e.g. it was
#           created by a different user or on a different machine).
#-------------------------------------------------------------------------------
function Read-StoredClientSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $encrypted = (Get-Content -LiteralPath $Path -Raw)
    if ([string]::IsNullOrWhiteSpace($encrypted)) {
        return $null
    }

    try {
        return ConvertTo-SecureString -String $encrypted.Trim()
    }
    catch {
        throw @"
Found a stored client secret at '$Path' but could not decrypt it.
DPAPI ciphertext can only be read by the same Windows user on the same machine
that created it. Re-run with -ResetCredential to capture and store it again.
($($_.Exception.Message))
"@
    }
}


#-------------------------------------------------------------------------------
# Resolve-ClientSecret
#
# Purpose : Return the client secret to authenticate with, either from the DPAPI
#           store or -- only when nothing usable is stored (or -Reset is set) --
#           via a one-time secure prompt, after which it is persisted for silent
#           reuse on later runs.
# Params  : -TenantId / -ClientId  Identify which stored secret to use.
#           -Reset                 Discard any stored secret and re-prompt.
# Returns : A SecureString. Throws if an empty secret is entered.
#-------------------------------------------------------------------------------
function Resolve-ClientSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $ClientId,

        [switch] $Reset
    )

    $storePath = Get-SecretStorePath -TenantId $TenantId -ClientId $ClientId

    if ($Reset -and (Test-Path -LiteralPath $storePath)) {
        Remove-Item -LiteralPath $storePath -Force
        Write-Host "Removed previously stored client secret (-ResetCredential)." -ForegroundColor DarkGray
    }

    if (-not $Reset) {
        $stored = Read-StoredClientSecret -Path $storePath
        if ($stored) {
            Write-Host "Using stored client secret for app '$ClientId'." -ForegroundColor DarkGray
            return $stored
        }
    }

    # No usable stored secret -- prompt once. Read-Host -AsSecureString masks the
    # input and never echoes it, so the plaintext stays out of console/logs.
    $secure = Read-Host -AsSecureString -Prompt "Enter the client secret for app '$ClientId'"
    if (-not $secure -or $secure.Length -eq 0) {
        throw "No client secret was entered. Cannot authenticate app-only."
    }

    Save-ClientSecret -SecureSecret $secure -Path $storePath
    Write-Host "Client secret stored securely (DPAPI, current user) at:" -ForegroundColor Green
    Write-Host "  $storePath" -ForegroundColor DarkGray

    return $secure
}


#-------------------------------------------------------------------------------
# Connect-GraphAppOnly
#
# Purpose : Perform an APP-ONLY (client-credentials) sign-in to Microsoft Graph.
#           The app registration must have the Application.Read.All APPLICATION
#           permission with admin consent; app-only tokens carry that permission,
#           so no -Scopes are requested here.
#
# NAMING  : Deliberately NOT named 'Connect-Graph'. Microsoft.Graph.Authentication
#           exports 'Connect-Graph' as an ALIAS for Connect-MgGraph, and in
#           PowerShell command resolution an alias OUTRANKS a same-named function.
#           A function called 'Connect-Graph' would therefore be silently shadowed
#           once the module is imported: the call would hit Connect-MgGraph, whose
#           '-ClientSecret' prefix-matches '-ClientSecretCredential' (a PSCredential),
#           and a SecureString passed there fails to bind. Keep this name distinct.
# Params  : -TenantId      Tenant id / domain to sign in against.
#           -ClientId      Application (client) id of the sign-in app.
#           -ClientSecret  The client secret as a SecureString.
# Returns : Nothing. Throws with a human-readable message if auth fails or the
#           resulting context is not app-only.
#-------------------------------------------------------------------------------
function Connect-GraphAppOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $ClientId,

        [Parameter(Mandatory)]
        [securestring] $ClientSecret
    )

    # -ClientSecretCredential expects a PSCredential whose UserName is the client
    # (app) id and whose password is the secret. Verified against Microsoft Learn.
    $credential = [System.Management.Automation.PSCredential]::new($ClientId, $ClientSecret)

    try {
        Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -NoWelcome | Out-Null
    }
    catch {
        throw "Failed to connect to Microsoft Graph (app-only): $($_.Exception.Message)"
    }

    $context = Get-MgContext
    if (-not $context) {
        throw "Connected to Microsoft Graph but no context was returned. Aborting."
    }
    if ($context.AuthType -ne 'AppOnly') {
        throw "Expected app-only authentication but Get-MgContext reports AuthType '$($context.AuthType)'."
    }

    Write-Host "Connected to tenant '$($context.TenantId)' as app '$($context.ClientId)' (AuthType: $($context.AuthType))." -ForegroundColor Green
}


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
    Initialize-RequiredModule -InstallMissing:$InstallMissingModules

    $clientSecret = Resolve-ClientSecret -TenantId $TenantId -ClientId $ClientId -Reset:$ResetCredential
    Connect-GraphAppOnly -TenantId $TenantId -ClientId $ClientId -ClientSecret $clientSecret
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
        Disconnect-MgGraph | Out-Null
        Write-Host "Disconnected from Microsoft Graph." -ForegroundColor DarkGray
    }
}
