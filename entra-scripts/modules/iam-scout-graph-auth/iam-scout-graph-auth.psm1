#Requires -Version 7.0
<#
================================================================================
 iam-scout-graph-auth

 Reusable Microsoft Graph APP-ONLY (client-credentials) authentication for
 iam_scout EntraID scripts: connect/disconnect, the DPAPI client-secret store,
 and a required-module presence/install check. Export/output logic (Excel,
 field selection) stays in the calling script.

 AUTHENTICATION (verified against Microsoft Learn, graph-powershell-1.0):
   - Client secret path: Connect-MgGraph -ClientSecretCredential <pscredential>
     -TenantId <tenant>, where the PSCredential's UserName is the client
     (app) id and its password is the secret.
   - Certificate path: Connect-MgGraph -ClientId <appId> -TenantId <tenant>
     with EITHER -CertificateThumbprint <thumbprint> OR -CertificateName
     <subject>. The certificate must already be present in the current
     user's or local machine's certificate store (Cert:\CurrentUser\My or
     Cert:\LocalMachine\My).
   - Get-MgContext.AuthType returns 'AppOnly' for a successful app-only
     connection in either path.

 CLIENT-SECRET STORAGE -- DESIGN & TRADE-OFFS:
   The secret is stored as a DPAPI-encrypted SecureString using ONLY built-in
   PowerShell/Windows capability (ConvertFrom-SecureString / ConvertTo-SecureString
   with no -Key). Verified against Microsoft Learn: "If no key is specified, the
   Windows Data Protection API (DPAPI) is used to encrypt the standard string."
   The ciphertext is written to a per-user file under %LOCALAPPDATA%, namespaced
   by tenant + client id so different apps never collide. DPAPI (CurrentUser
   scope) binds the ciphertext to this Windows user on this machine; another
   user or machine cannot decrypt it and will be re-prompted. The plaintext
   secret is never written to console output, logs, or transcripts.
================================================================================
#>

Set-StrictMode -Version Latest

#-------------------------------------------------------------------------------
# Initialize-IamScoutRequiredModule
#
# Purpose : Ensure every module in -ModuleName is available (optionally
#           installing missing ones), without loading them.
# Params  : -ModuleName      Modules to check.
#           -InstallMissing  When set, missing modules are installed from the
#                             PowerShell Gallery (CurrentUser scope). When not
#                             set, the function reports what to install and
#                             throws.
# Returns : Nothing. Throws if a module is missing (and not installed) or if
#           an install fails.
#-------------------------------------------------------------------------------
function Initialize-IamScoutRequiredModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $ModuleName,

        [switch] $InstallMissing
    )

    $missing = @()

    foreach ($module in $ModuleName) {
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

Or re-run with -InstallMissingModules to install them automatically.
"@
    }
}


#-------------------------------------------------------------------------------
# Get-IamScoutSecretStorePath (private)
#
# Purpose : Return the per-user file path where this tenant+app's DPAPI-encrypted
#           client secret is (or will be) stored. The directory is created if it
#           does not yet exist.
# Params  : -TenantId / -ClientId  Used to namespace the file so secrets for
#                                  different apps never collide.
# Returns : A full file path (string). The file itself may or may not exist yet.
#-------------------------------------------------------------------------------
function Get-IamScoutSecretStorePath {
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
# Save-IamScoutClientSecret (private)
#
# Purpose : Persist a client secret to disk as a DPAPI-encrypted string. With no
#           -Key, ConvertFrom-SecureString encrypts via the Windows Data Protection
#           API bound to the current user + machine (verified on Microsoft Learn).
#           Only ciphertext is written; the plaintext secret never leaves memory.
#-------------------------------------------------------------------------------
function Save-IamScoutClientSecret {
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
# Read-IamScoutStoredClientSecret (private)
#
# Purpose : Reconstruct a previously stored client secret. ConvertTo-SecureString
#           with no -Key reverses the DPAPI encryption for the same user/machine.
# Returns : A SecureString, or $null if no (usable) stored secret exists. Throws a
#           helpful message if a file exists but cannot be decrypted (e.g. it was
#           created by a different user or on a different machine).
#-------------------------------------------------------------------------------
function Read-IamScoutStoredClientSecret {
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
# Resolve-IamScoutClientSecret (private)
#
# Purpose : Return the client secret to authenticate with, either from the DPAPI
#           store or -- only when nothing usable is stored (or -Reset is set) --
#           via a one-time secure prompt, after which it is persisted for silent
#           reuse on later runs.
# Params  : -TenantId / -ClientId  Identify which stored secret to use.
#           -Reset                 Discard any stored secret and re-prompt.
# Returns : A SecureString. Throws if an empty secret is entered.
#-------------------------------------------------------------------------------
function Resolve-IamScoutClientSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $ClientId,

        [switch] $Reset
    )

    $storePath = Get-IamScoutSecretStorePath -TenantId $TenantId -ClientId $ClientId

    if ($Reset -and (Test-Path -LiteralPath $storePath)) {
        Remove-Item -LiteralPath $storePath -Force
        Write-Host "Removed previously stored client secret (-ResetCredential)." -ForegroundColor DarkGray
    }

    if (-not $Reset) {
        $stored = Read-IamScoutStoredClientSecret -Path $storePath
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

    Save-IamScoutClientSecret -SecureSecret $secure -Path $storePath
    Write-Host "Client secret stored securely (DPAPI, current user) at:" -ForegroundColor Green
    Write-Host "  $storePath" -ForegroundColor DarkGray

    return $secure
}


#-------------------------------------------------------------------------------
# Connect-IamScoutGraph
#
# Purpose : Perform an APP-ONLY (client-credentials) sign-in to Microsoft Graph,
#           via either a certificate already present in the local cert store or
#           a DPAPI-stored/prompted client secret.
#
# NAMING  : Deliberately NOT named 'Connect-Graph'. Microsoft.Graph.Authentication
#           exports 'Connect-Graph' as an ALIAS for Connect-MgGraph, and in
#           PowerShell command resolution an alias OUTRANKS a same-named function.
#           A function called 'Connect-Graph' would therefore be silently shadowed
#           once the module is imported.
# Params  : -TenantId               Tenant id / domain to sign in against.
#           -ClientId               Application (client) id of the sign-in app.
#           -CertificateThumbprint  (Certificate parameter set) Cert thumbprint
#                                   in Cert:\CurrentUser\My or Cert:\LocalMachine\My.
#           -CertificateName        (Certificate parameter set) Cert subject name,
#                                   alternative to -CertificateThumbprint.
#           -ResetCredential        (ClientSecret parameter set) Discard any stored
#                                   secret and re-prompt (e.g. after rotation).
# Returns : Nothing. Throws with a human-readable message if auth fails or the
#           resulting context is not app-only.
#-------------------------------------------------------------------------------
function Connect-IamScoutGraph {
    [CmdletBinding(DefaultParameterSetName = 'ClientSecret')]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $ClientId,

        [Parameter(Mandatory, ParameterSetName = 'Certificate')]
        [string] $CertificateThumbprint,

        [Parameter(Mandatory, ParameterSetName = 'Certificate')]
        [string] $CertificateName,

        [Parameter(ParameterSetName = 'ClientSecret')]
        [switch] $ResetCredential
    )

    if ($PSCmdlet.ParameterSetName -eq 'Certificate') {
        $connectParams = @{
            ClientId = $ClientId
            TenantId = $TenantId
            NoWelcome = $true
        }
        if ($PSBoundParameters.ContainsKey('CertificateThumbprint')) {
            $connectParams['CertificateThumbprint'] = $CertificateThumbprint
        }
        else {
            $connectParams['CertificateName'] = $CertificateName
        }

        try {
            Connect-MgGraph @connectParams | Out-Null
        }
        catch {
            throw "Failed to connect to Microsoft Graph (app-only, certificate): $($_.Exception.Message)"
        }
    }
    else {
        $clientSecret = Resolve-IamScoutClientSecret -TenantId $TenantId -ClientId $ClientId -Reset:$ResetCredential

        # -ClientSecretCredential expects a PSCredential whose UserName is the
        # client (app) id and whose password is the secret. Verified against
        # Microsoft Learn.
        $credential = [System.Management.Automation.PSCredential]::new($ClientId, $clientSecret)

        try {
            Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -NoWelcome | Out-Null
        }
        catch {
            throw "Failed to connect to Microsoft Graph (app-only, client secret): $($_.Exception.Message)"
        }
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
# Disconnect-IamScoutGraph
#
# Purpose : Disconnect from Microsoft Graph if currently connected. Safe to call
#           even when there is no active connection.
# Returns : Nothing.
#-------------------------------------------------------------------------------
function Disconnect-IamScoutGraph {
    [CmdletBinding()]
    param()

    if (Get-MgContext) {
        Disconnect-MgGraph | Out-Null
        Write-Host "Disconnected from Microsoft Graph." -ForegroundColor DarkGray
    }
}


Export-ModuleMember -Function @(
    'Initialize-IamScoutRequiredModule'
    'Connect-IamScoutGraph'
    'Disconnect-IamScoutGraph'
)
