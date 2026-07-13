#Requires -Version 7.0
<#
================================================================================
 export-entra-identity-inventory.ps1

 Phase 3 read-only identity & tenant configuration inventory. A separate
 workbook from the app-registration export because these entity domains
 (users, directory roles, cross-tenant access policy) do not join to that
 workbook's Core sheet by AppId.

 Sheets:
   Users                     one row per user (Get-MgUser -All)
   DirectoryRoles            one row per ACTIVATED directory role
   DirectoryRoleMembers      one row per role member (join via RoleId)
   CrossTenantAccessDefault  one row: tenant-wide baseline policy
   CrossTenantAccessPartners one row per partner tenant override

 KNOWN GAPS:
   - DirectoryRoles/DirectoryRoleMembers surface only *activated* directory
     roles and their current members. PIM-eligible assignments that have
     never been activated do not appear here.
   - The legacy /directoryRoles/{id}/members endpoint used here can omit
     service-principal members that the modern
     /roleManagement/directory/roleAssignments endpoint does report
     (observed live 2026-07-13: an SP with an active tenant-wide Global
     Reader assignment was returned by roleAssignments and by the SP's own
     memberOf, but not by the role's members or scopedMembers lists). Treat
     DirectoryRoleMembers as user-membership-reliable, not SP-complete.

 Every Graph call is read-only (Get-Mg*). The cross-tenant policy reads
 need Policy.Read.All (application) per Microsoft Learn; if the tenant
 hasn't consented it, those two sheets are skipped with a warning rather
 than aborting the user/role export.

 HOW TO RUN:
   pwsh ./export-entra-identity-inventory.ps1 -TenantId <tenant> -ClientId <appId>
   (TenantId/ClientId fall back to the config.psd1 defaults saved via
   Set-IamScoutGraphDefault when omitted.)
================================================================================
#>

[CmdletBinding()]
param(
    # Tenant id (GUID) or verified domain. Falls back to the module's
    # config.psd1 default (Set-IamScoutGraphDefault) when omitted.
    [Parameter()]
    [string] $TenantId,

    # Application (client) id of the sign-in app. Same fallback as -TenantId.
    [Parameter()]
    [string] $ClientId,

    # Folder to write the .xlsx into. Defaults to the current directory.
    [Parameter()]
    [string] $OutputDirectory = (Get-Location).Path,

    # If a required module is missing, install it (CurrentUser scope) instead
    # of stopping with instructions.
    [Parameter()]
    [switch] $InstallMissingModules,

    # Discard any previously stored client secret and re-prompt.
    [Parameter()]
    [switch] $ResetCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RequiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Identity.DirectoryManagement'
    'Microsoft.Graph.Identity.SignIns'
    'ImportExcel'
)

# Permission notes (Microsoft Learn, graph-rest-1.0, verified 2026-07-13):
#   List users:                least-priv app permission User.Read.All;
#                              Directory.Read.All also covers it.
#   List directoryRoles/members: least-priv RoleManagement.Read.Directory;
#                              Directory.Read.All also covers it.
#   Cross-tenant access policy default/partners: Policy.Read.All.
# App-only tokens carry whatever the tenant consented (or whatever the SP's
# directory-role membership grants), so nothing here is passed to
# Connect-MgGraph -- documentary only.
$script:CrossTenantRequiredPermission = 'Policy.Read.All'

# Bootstrap: the auth module's manifest declares
# RequiredModules = @('Microsoft.Graph.Authentication'), so this import fails
# on a fresh machine before Initialize-IamScoutRequiredModule (which lives
# inside that module) could ever honor -InstallMissingModules. Ensure the one
# manifest dependency exists first; the full module check still runs in Main.
if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
    if ($InstallMissingModules) {
        Write-Host "  [install] Microsoft.Graph.Authentication not found -- installing (CurrentUser)..." -ForegroundColor Yellow
        Install-Module -Name 'Microsoft.Graph.Authentication' -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    else {
        Write-Error @"
Missing required module: Microsoft.Graph.Authentication

Install it and re-run, for example:
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

Or re-run with -InstallMissingModules to install it automatically.
"@
        exit 1
    }
}

Import-Module (Join-Path $PSScriptRoot 'modules/iam-scout-graph-auth/iam-scout-graph-auth.psd1') -Force


#-------------------------------------------------------------------------------
# ConvertTo-IamScoutJson
#
# Purpose : Compact-serialize a nested/complex Graph property for a sheet cell.
#           Returns '' for $null so every row has the same columns populated.
#-------------------------------------------------------------------------------
function ConvertTo-IamScoutJson {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [object] $InputObject
    )
    process {
        if ($null -eq $InputObject) { return '' }
        return ($InputObject | ConvertTo-Json -Compress -Depth 8)
    }
}


#-------------------------------------------------------------------------------
# Get-UserInventory
#
# Purpose : Retrieve all users with the Phase 3 core fields. accountEnabled,
#           userType and createdDateTime are not in Graph's default user
#           $select set, so every field is requested explicitly.
# Returns : Array of one flat record per user.
#-------------------------------------------------------------------------------
function Get-UserInventory {
    [CmdletBinding()]
    param()

    $selectProperties = @(
        'id'
        'userPrincipalName'
        'displayName'
        'accountEnabled'
        'userType'
        'createdDateTime'
    )

    try {
        Write-Host "Retrieving users..." -ForegroundColor Cyan
        $users = @(Get-MgUser -All -Property $selectProperties)
    }
    catch {
        throw "Failed to retrieve users from Microsoft Graph: $($_.Exception.Message)"
    }

    Write-Host "Found $($users.Count) user(s)." -ForegroundColor Cyan

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($user in $users) {
        $records.Add([pscustomobject][ordered]@{
            Id                = $user.Id
            UserPrincipalName = $user.UserPrincipalName
            DisplayName       = $user.DisplayName
            AccountEnabled    = $user.AccountEnabled
            UserType          = $user.UserType
            CreatedDateTime   = $user.CreatedDateTime
        })
    }
    return $records.ToArray()
}


#-------------------------------------------------------------------------------
# Get-DirectoryRoleInventory
#
# Purpose : Retrieve all ACTIVATED directory roles and their members.
#           Get-MgDirectoryRoleMember returns bare directoryObject references,
#           so member type/display name are resolved from AdditionalProperties
#           ('@odata.type' / 'displayName') rather than typed properties.
#           PIM-eligible-but-not-activated assignments never appear here
#           (documented gap, see header).
# Returns : PSCustomObject with Roles / Members array properties, joined by
#           RoleId.
#-------------------------------------------------------------------------------
function Get-DirectoryRoleInventory {
    [CmdletBinding()]
    param()

    try {
        Write-Host "Retrieving activated directory roles..." -ForegroundColor Cyan
        $roles = @(Get-MgDirectoryRole -All)
    }
    catch {
        throw "Failed to retrieve directory roles from Microsoft Graph: $($_.Exception.Message)"
    }

    Write-Host "Found $($roles.Count) activated directory role(s)." -ForegroundColor Cyan

    $roleRecords   = [System.Collections.Generic.List[object]]::new()
    $memberRecords = [System.Collections.Generic.List[object]]::new()

    foreach ($role in $roles) {
        $roleRecords.Add([pscustomobject][ordered]@{
            RoleId         = $role.Id
            RoleTemplateId = $role.RoleTemplateId
            DisplayName    = $role.DisplayName
            Description    = $role.Description
        })

        try {
            $members = @(Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All)
        }
        catch {
            Write-Warning "Failed to retrieve members for directory role '$($role.DisplayName)' ($($role.Id)): $($_.Exception.Message)"
            continue
        }

        foreach ($member in $members) {
            $memberType = if ($member.AdditionalProperties -and $member.AdditionalProperties['@odata.type']) {
                ($member.AdditionalProperties['@odata.type'] -replace '^#microsoft\.graph\.', '')
            } else {
                ''
            }
            $memberDisplayName = if ($member.AdditionalProperties -and $member.AdditionalProperties['displayName']) {
                $member.AdditionalProperties['displayName']
            } else {
                ''
            }
            $memberRecords.Add([pscustomobject][ordered]@{
                RoleId            = $role.Id
                RoleDisplayName   = $role.DisplayName
                MemberId          = $member.Id
                MemberType        = $memberType
                MemberDisplayName = $memberDisplayName
            })
        }
    }

    return [pscustomobject]@{
        Roles   = $roleRecords.ToArray()
        Members = $memberRecords.ToArray()
    }
}


#-------------------------------------------------------------------------------
# Get-B2BAccessType (private helper)
#
# Purpose : Pull the usersAndGroups/applications accessType pair out of one
#           crossTenantAccessPolicyB2BSetting into a compact readable string,
#           e.g. 'users=allowed; apps=allowed'. Partner settings inherit from
#           the default policy when null, so '' here means "inherits default"
#           on partner rows and should not be read as "blocked".
#-------------------------------------------------------------------------------
function Get-B2BAccessType {
    [CmdletBinding()]
    param(
        [object] $Setting
    )

    if ($null -eq $Setting) { return '' }

    $users = if ($Setting.UsersAndGroups -and $Setting.UsersAndGroups.AccessType) { $Setting.UsersAndGroups.AccessType } else { '' }
    $apps  = if ($Setting.Applications  -and $Setting.Applications.AccessType)  { $Setting.Applications.AccessType }  else { '' }

    if (-not $users -and -not $apps) { return '' }
    return "users=$users; apps=$apps"
}


#-------------------------------------------------------------------------------
# Get-CrossTenantAccessConfiguration
#
# Purpose : Retrieve the tenant-wide default cross-tenant access policy and
#           all per-partner overrides. Needs Policy.Read.All (application);
#           if the call is denied, warns and returns empty arrays so the
#           user/role export still completes (graceful degrade, mirroring the
#           Phase 2 oauth2PermissionGrants pattern).
# Returns : PSCustomObject with DefaultPolicy / Partners array properties.
#-------------------------------------------------------------------------------
function Get-CrossTenantAccessConfiguration {
    [CmdletBinding()]
    param()

    $defaultRecords = [System.Collections.Generic.List[object]]::new()
    $partnerRecords = [System.Collections.Generic.List[object]]::new()

    try {
        Write-Host "Retrieving cross-tenant access policy (default + partners)..." -ForegroundColor Cyan
        $default  = Get-MgPolicyCrossTenantAccessPolicyDefault
        $partners = @(Get-MgPolicyCrossTenantAccessPolicyPartner -All)
    }
    catch {
        Write-Warning "Failed to retrieve cross-tenant access policy (requires '$script:CrossTenantRequiredPermission' application permission) -- skipping the CrossTenantAccessDefault/CrossTenantAccessPartners sheets. Error: $($_.Exception.Message)"
        return [pscustomobject]@{
            DefaultPolicy = $defaultRecords.ToArray()
            Partners      = $partnerRecords.ToArray()
        }
    }

    if ($default) {
        $defaultRecords.Add([pscustomobject][ordered]@{
            IsServiceDefault               = $default.IsServiceDefault
            B2BCollaborationInbound        = Get-B2BAccessType $default.B2BCollaborationInbound
            B2BCollaborationOutbound       = Get-B2BAccessType $default.B2BCollaborationOutbound
            B2BDirectConnectInbound        = Get-B2BAccessType $default.B2BDirectConnectInbound
            B2BDirectConnectOutbound       = Get-B2BAccessType $default.B2BDirectConnectOutbound
            InboundTrustJson               = ConvertTo-IamScoutJson $default.InboundTrust
            AutomaticUserConsentJson       = ConvertTo-IamScoutJson $default.AutomaticUserConsentSettings
            B2BCollaborationInboundJson    = ConvertTo-IamScoutJson $default.B2BCollaborationInbound
            B2BCollaborationOutboundJson   = ConvertTo-IamScoutJson $default.B2BCollaborationOutbound
            B2BDirectConnectInboundJson    = ConvertTo-IamScoutJson $default.B2BDirectConnectInbound
            B2BDirectConnectOutboundJson   = ConvertTo-IamScoutJson $default.B2BDirectConnectOutbound
        })
    }

    Write-Host "Found $($partners.Count) partner-specific cross-tenant configuration(s)." -ForegroundColor Cyan

    foreach ($partner in $partners) {
        $partnerRecords.Add([pscustomobject][ordered]@{
            TenantId                       = $partner.TenantId
            IsServiceProvider              = $partner.IsServiceProvider
            IsInMultiTenantOrganization    = $partner.IsInMultiTenantOrganization
            B2BCollaborationInbound        = Get-B2BAccessType $partner.B2BCollaborationInbound
            B2BCollaborationOutbound       = Get-B2BAccessType $partner.B2BCollaborationOutbound
            B2BDirectConnectInbound        = Get-B2BAccessType $partner.B2BDirectConnectInbound
            B2BDirectConnectOutbound       = Get-B2BAccessType $partner.B2BDirectConnectOutbound
            InboundTrustJson               = ConvertTo-IamScoutJson $partner.InboundTrust
            AutomaticUserConsentJson       = ConvertTo-IamScoutJson $partner.AutomaticUserConsentSettings
            B2BCollaborationInboundJson    = ConvertTo-IamScoutJson $partner.B2BCollaborationInbound
            B2BCollaborationOutboundJson   = ConvertTo-IamScoutJson $partner.B2BCollaborationOutbound
            B2BDirectConnectInboundJson    = ConvertTo-IamScoutJson $partner.B2BDirectConnectInbound
            B2BDirectConnectOutboundJson   = ConvertTo-IamScoutJson $partner.B2BDirectConnectOutbound
        })
    }

    return [pscustomobject]@{
        DefaultPolicy = $defaultRecords.ToArray()
        Partners      = $partnerRecords.ToArray()
    }
}


#-------------------------------------------------------------------------------
# Export-IdentityInventory
#
# Purpose : Write the collected inventory to a single timestamped .xlsx
#           workbook. The Users sheet is always written when the run reaches
#           export (even 0 rows is guarded in Main); other sheets are omitted
#           when empty (Export-Excel requires at least one row per worksheet).
#           All sheet names are <= 31 chars (Excel worksheet-name cap).
# Returns : The full path of the .xlsx file written. Throws on failure.
#-------------------------------------------------------------------------------
function Export-IdentityInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Users,

        [Parameter(Mandatory)]
        [pscustomobject] $RoleData,

        [Parameter(Mandatory)]
        [pscustomobject] $CrossTenantData,

        [Parameter(Mandatory)]
        [string] $OutputDirectory
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $fileName  = "EntraIdentityInventory_$timestamp.xlsx"
    $fullPath  = Join-Path -Path $OutputDirectory -ChildPath $fileName

    $sheets = @(
        @{ Name = 'Users';                     Table = 'Users';                     Records = $Users }
        @{ Name = 'DirectoryRoles';            Table = 'DirectoryRoles';            Records = $RoleData.Roles }
        @{ Name = 'DirectoryRoleMembers';      Table = 'DirectoryRoleMembers';      Records = $RoleData.Members }
        @{ Name = 'CrossTenantAccessDefault';  Table = 'CrossTenantAccessDefault';  Records = $CrossTenantData.DefaultPolicy }
        @{ Name = 'CrossTenantAccessPartners'; Table = 'CrossTenantAccessPartners'; Records = $CrossTenantData.Partners }
    )

    try {
        foreach ($sheet in $sheets) {
            $rows = @($sheet.Records)
            if ($rows.Count -eq 0) {
                if ($sheet.Name -ne 'Users') { continue }
            }

            $rows | Export-Excel `
                -Path $fullPath `
                -WorksheetName $sheet.Name `
                -TableName $sheet.Table `
                -TableStyle 'Medium2' `
                -AutoSize `
                -FreezeTopRow `
                -BoldTopRow
        }
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
    Import-Module Microsoft.Graph.Authentication                 -ErrorAction Stop
    Import-Module Microsoft.Graph.Users                          -ErrorAction Stop
    Import-Module Microsoft.Graph.Identity.DirectoryManagement   -ErrorAction Stop
    Import-Module Microsoft.Graph.Identity.SignIns               -ErrorAction Stop
    Import-Module ImportExcel                                    -ErrorAction Stop

    $connectParams = @{ ResetCredential = $ResetCredential }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    if ($ClientId) { $connectParams['ClientId'] = $ClientId }
    Connect-IamScoutGraph @connectParams
    $connected = $true

    $users           = @(Get-UserInventory)
    $roleData        = Get-DirectoryRoleInventory
    $crossTenantData = Get-CrossTenantAccessConfiguration

    if ($users.Count -eq 0 -and @($roleData.Roles).Count -eq 0 -and @($crossTenantData.DefaultPolicy).Count -eq 0) {
        Write-Warning "No users, directory roles, or cross-tenant policy data retrieved. Nothing to export."
    }
    else {
        $outputFile = Export-IdentityInventory -Users $users -RoleData $roleData `
            -CrossTenantData $crossTenantData -OutputDirectory $OutputDirectory
        Write-Host ("Exported {0} user(s), {1} directory role(s) ({2} member row(s)), {3} cross-tenant partner(s) to:" -f `
            $users.Count, @($roleData.Roles).Count, @($roleData.Members).Count, @($crossTenantData.Partners).Count) -ForegroundColor Green
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
