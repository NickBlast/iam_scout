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
    [switch] $ResetCredential,

    # Credentials whose EndDateTime falls within this many days from now are
    # marked 'ExpiringSoon' in the computed ExpiryStatus column on the four
    # credential sheets (KeyCredentials, PasswordCredentials,
    # SPKeyCredentials, SPPasswordCredentials).
    [Parameter()]
    [ValidateRange(1, 3650)]
    [int] $ExpiringSoonThresholdDays = 30
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

# Service Principal oauth2PermissionGrant (delegated permissions) reads need
# Directory.Read.All -- broader than $script:RequiredAppRole above (verified
# against Microsoft Learn graph-rest-1.0 serviceprincipal-list-oauth2permissiongrants).
# Everything else SP-related (the SP object, appRoleAssignments, memberOf)
# stays within Application.Read.All. If this scope isn't consented,
# Get-ServicePrincipalInventory degrades gracefully (warns, leaves that SP's
# delegated-permission rows empty) rather than aborting the export.
$script:OptionalAppRoleForDelegatedGrants = 'Directory.Read.All'

Import-Module (Join-Path $PSScriptRoot 'modules/iam-scout-graph-auth/iam-scout-graph-auth.psd1') -Force


#-------------------------------------------------------------------------------
# ConvertTo-IamScoutJson
#
# Purpose : Compact-serialize a nested/complex Graph property for a Core-sheet
#           cell. Returns '' for $null so every app's Core row has the same
#           columns populated (possibly empty) rather than missing values.
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
# Get-IamScoutExpiryStatus
#
# Purpose : Classify a credential's EndDateTime for the computed ExpiryStatus
#           column on the four credential sheets: 'Expired' (end date in the
#           past), 'ExpiringSoon' (within -ExpiringSoonThresholdDays from
#           now), 'OK' (later than that), or '' when Graph returned no end
#           date. Comparison is done in UTC (Graph returns UTC datetimes).
#-------------------------------------------------------------------------------
function Get-IamScoutExpiryStatus {
    [CmdletBinding()]
    param(
        [Parameter()]
        [nullable[datetime]] $EndDateTime
    )

    if ($null -eq $EndDateTime) { return '' }

    $nowUtc = (Get-Date).ToUniversalTime()
    $endUtc = $EndDateTime.ToUniversalTime()

    if ($endUtc -lt $nowUtc) { return 'Expired' }
    if ($endUtc -lt $nowUtc.AddDays($ExpiringSoonThresholdDays)) { return 'ExpiringSoon' }
    return 'OK'
}


#-------------------------------------------------------------------------------
# Get-AppRegistration
#
# Purpose : Retrieve all app registrations and flatten them into a fixed schema:
#           one "Core" record per app (every top-level scalar/simple property,
#           plus JSON-serialized nested settings that aren't broken into their
#           own sheet), and one record per entry in each multi-value collection
#           (redirect URIs, requiredResourceAccess, keyCredentials,
#           passwordCredentials metadata, appRoles, oauth2PermissionScopes),
#           each carrying the parent app's AppId as a join key. Every app
#           appears in Core even if every collection is empty for it.
# Params  : -IncludeOwners  When set, makes one Get-MgApplicationOwner call per app
#                           and adds a semicolon-delimited Owners column to Core.
# Returns : A PSCustomObject with Core/RedirectUris/RequiredResourceAccess/
#           KeyCredentials/PasswordCredentials/AppRoles/Oauth2PermissionScopes
#           array properties. Throws if retrieval fails.
#-------------------------------------------------------------------------------
function Get-AppRegistration {
    [CmdletBinding()]
    param(
        [switch] $IncludeOwners
    )

    # Full set of top-level `application` resource properties (Microsoft Graph
    # v1.0 reference, docs/LEARNINGS.md 2026-07-09 entry). Excludes `logo`
    # (Stream type; not retrievable via list -Property/$select). -All is
    # required because Get-MgApplication returns only the first page by default.
    $selectProperties = @(
        'id'
        'appId'
        'displayName'
        'signInAudience'
        'publisherDomain'
        'createdDateTime'
        'deletedDateTime'
        'description'
        'notes'
        'disabledByMicrosoftStatus'
        'tags'
        'identifierUris'
        'groupMembershipClaims'
        'isDeviceOnlyAuthSupported'
        'isFallbackPublicClient'
        'oauth2RequiredPostResponse'
        'applicationTemplateId'
        'createdByAppId'
        'serviceManagementReference'
        'samlMetadataUrl'
        'uniqueName'
        'tokenEncryptionKeyId'
        'nativeAuthenticationApisEnabled'
        'verifiedPublisher'
        'certification'
        'info'
        'optionalClaims'
        'parentalControlSettings'
        'requestSignatureVerification'
        'servicePrincipalLockConfiguration'
        'addIns'
        'managerApplications'
        'api'
        'web'
        'spa'
        'publicClient'
        'keyCredentials'
        'passwordCredentials'
        'requiredResourceAccess'
        'appRoles'
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

    $core                  = [System.Collections.Generic.List[object]]::new()
    $redirectUris          = [System.Collections.Generic.List[object]]::new()
    $requiredResourceAccess = [System.Collections.Generic.List[object]]::new()
    $keyCredentials        = [System.Collections.Generic.List[object]]::new()
    $passwordCredentials   = [System.Collections.Generic.List[object]]::new()
    $appRoles              = [System.Collections.Generic.List[object]]::new()
    $oauth2Scopes          = [System.Collections.Generic.List[object]]::new()

    if ($applications.Count -eq 0) {
        return [pscustomobject]@{
            Core                    = $core.ToArray()
            RedirectUris            = $redirectUris.ToArray()
            RequiredResourceAccess  = $requiredResourceAccess.ToArray()
            KeyCredentials          = $keyCredentials.ToArray()
            PasswordCredentials     = $passwordCredentials.ToArray()
            AppRoles                = $appRoles.ToArray()
            Oauth2PermissionScopes  = $oauth2Scopes.ToArray()
        }
    }

    $index = 0

    foreach ($app in $applications) {
        $index++

        $coreRecord = [ordered]@{
            DisplayName                     = $app.DisplayName
            AppId                           = $app.AppId
            Id                              = $app.Id            # object id
            SignInAudience                  = $app.SignInAudience
            PublisherDomain                 = $app.PublisherDomain
            CreatedDateTime                 = $app.CreatedDateTime
            DeletedDateTime                 = $app.DeletedDateTime
            Description                     = $app.Description
            Notes                           = $app.Notes
            DisabledByMicrosoftStatus       = $app.DisabledByMicrosoftStatus
            Tags                            = if ($app.Tags) { $app.Tags -join '; ' } else { '' }
            IdentifierUris                  = if ($app.IdentifierUris) { $app.IdentifierUris -join '; ' } else { '' }
            GroupMembershipClaims           = $app.GroupMembershipClaims
            IsDeviceOnlyAuthSupported       = $app.IsDeviceOnlyAuthSupported
            IsFallbackPublicClient          = $app.IsFallbackPublicClient
            OAuth2RequiredPostResponse      = $app.Oauth2RequirePostResponse
            ApplicationTemplateId           = $app.ApplicationTemplateId
            CreatedByAppId                  = $app.CreatedByAppId
            ServiceManagementReference      = $app.ServiceManagementReference
            SamlMetadataUrl                 = $app.SamlMetadataUrl
            UniqueName                      = $app.UniqueName
            TokenEncryptionKeyId            = $app.TokenEncryptionKeyId
            NativeAuthenticationApisEnabled = $app.NativeAuthenticationApisEnabled
            ManagerApplications             = if ($app.ManagerApplications) { $app.ManagerApplications -join '; ' } else { '' }
            VerifiedPublisherJson           = ConvertTo-IamScoutJson $app.VerifiedPublisher
            CertificationJson               = ConvertTo-IamScoutJson $app.Certification
            InfoJson                        = ConvertTo-IamScoutJson $app.Info
            OptionalClaimsJson              = ConvertTo-IamScoutJson $app.OptionalClaims
            ParentalControlSettingsJson     = ConvertTo-IamScoutJson $app.ParentalControlSettings
            RequestSignatureVerificationJson = ConvertTo-IamScoutJson $app.RequestSignatureVerification
            ServicePrincipalLockConfigurationJson = ConvertTo-IamScoutJson $app.ServicePrincipalLockConfiguration
            AddInsJson                      = ConvertTo-IamScoutJson $app.AddIns
            ApiSettingsJson                 = ConvertTo-IamScoutJson ($app.Api | Select-Object AcceptMappedClaims, KnownClientApplications, PreAuthorizedApplications, RequestedAccessTokenVersion)
            WebSettingsJson                 = ConvertTo-IamScoutJson ($app.Web | Select-Object HomePageUrl, LogoutUrl, ImplicitGrantSettings)
        }

        if ($IncludeOwners) {
            Write-Progress -Activity 'Collecting owners' `
                -Status "$index of $($applications.Count): $($app.DisplayName)" `
                -PercentComplete (($index / $applications.Count) * 100)

            $coreRecord['Owners'] = Get-OwnerDisplay -ApplicationId $app.Id
        }

        $core.Add([pscustomobject]$coreRecord)

        # --- Redirect URIs (web / spa / publicClient) ---
        foreach ($source in @(
            @{ Type = 'Web';          Uris = $app.Web.RedirectUris }
            @{ Type = 'Spa';          Uris = $app.Spa.RedirectUris }
            @{ Type = 'PublicClient'; Uris = $app.PublicClient.RedirectUris }
        )) {
            foreach ($uri in @($source.Uris)) {
                if ($null -eq $uri) { continue }
                $redirectUris.Add([pscustomobject][ordered]@{
                    AppId       = $app.AppId
                    DisplayName = $app.DisplayName
                    Type        = $source.Type
                    RedirectUri = $uri
                })
            }
        }

        # --- requiredResourceAccess (API permissions) ---
        foreach ($rra in @($app.RequiredResourceAccess)) {
            if ($null -eq $rra) { continue }
            foreach ($access in @($rra.ResourceAccess)) {
                $requiredResourceAccess.Add([pscustomobject][ordered]@{
                    AppId         = $app.AppId
                    DisplayName   = $app.DisplayName
                    ResourceAppId = $rra.ResourceAppId
                    PermissionId  = $access.Id
                    PermissionType = $access.Type   # 'Scope' (delegated) or 'Role' (application)
                })
            }
        }

        # --- keyCredentials (metadata only -- raw key bytes never selected) ---
        foreach ($key in @($app.KeyCredentials)) {
            if ($null -eq $key) { continue }
            $keyCredentials.Add([pscustomobject][ordered]@{
                AppId               = $app.AppId
                DisplayName         = $app.DisplayName
                KeyId               = $key.KeyId
                CredentialDisplayName = $key.DisplayName
                Type                = $key.Type
                Usage               = $key.Usage
                StartDateTime       = $key.StartDateTime
                EndDateTime         = $key.EndDateTime
                ExpiryStatus        = Get-IamScoutExpiryStatus -EndDateTime $key.EndDateTime
            })
        }

        # --- passwordCredentials (metadata only -- secretText is never
        #     returned by Graph on read; only present on the one-time
        #     addPassword response, so it is not requested or emitted here) ---
        foreach ($pwd in @($app.PasswordCredentials)) {
            if ($null -eq $pwd) { continue }
            $passwordCredentials.Add([pscustomobject][ordered]@{
                AppId               = $app.AppId
                DisplayName         = $app.DisplayName
                KeyId               = $pwd.KeyId
                CredentialDisplayName = $pwd.DisplayName
                Hint                = $pwd.Hint
                StartDateTime       = $pwd.StartDateTime
                EndDateTime         = $pwd.EndDateTime
                ExpiryStatus        = Get-IamScoutExpiryStatus -EndDateTime $pwd.EndDateTime
            })
        }

        # --- appRoles ---
        foreach ($role in @($app.AppRoles)) {
            if ($null -eq $role) { continue }
            $appRoles.Add([pscustomobject][ordered]@{
                AppId              = $app.AppId
                DisplayName        = $app.DisplayName
                Id                 = $role.Id
                Value              = $role.Value
                RoleDisplayName    = $role.DisplayName
                Description        = $role.Description
                AllowedMemberTypes = if ($role.AllowedMemberTypes) { $role.AllowedMemberTypes -join '; ' } else { '' }
                IsEnabled          = $role.IsEnabled
                Origin             = $role.Origin
            })
        }

        # --- oauth2PermissionScopes (nested under api) ---
        foreach ($scope in @($app.Api.Oauth2PermissionScopes)) {
            if ($null -eq $scope) { continue }
            $oauth2Scopes.Add([pscustomobject][ordered]@{
                AppId                  = $app.AppId
                DisplayName            = $app.DisplayName
                Id                     = $scope.Id
                Value                  = $scope.Value
                Type                   = $scope.Type
                IsEnabled              = $scope.IsEnabled
                AdminConsentDisplayName = $scope.AdminConsentDisplayName
                AdminConsentDescription = $scope.AdminConsentDescription
                UserConsentDisplayName = $scope.UserConsentDisplayName
                UserConsentDescription = $scope.UserConsentDescription
                Origin                 = $scope.Origin
            })
        }
    }

    if ($IncludeOwners) {
        Write-Progress -Activity 'Collecting owners' -Completed
    }

    return [pscustomobject]@{
        Core                    = $core.ToArray()
        RedirectUris            = $redirectUris.ToArray()
        RequiredResourceAccess  = $requiredResourceAccess.ToArray()
        KeyCredentials          = $keyCredentials.ToArray()
        PasswordCredentials     = $passwordCredentials.ToArray()
        AppRoles                = $appRoles.ToArray()
        Oauth2PermissionScopes  = $oauth2Scopes.ToArray()
    }
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
# Get-ServicePrincipalInventory
#
# Purpose : For each app registration's Core row, resolve its Service
#           Principal (if one exists) and flatten it plus its credential
#           metadata, granted application permissions (appRoleAssignments),
#           granted delegated permissions (oauth2PermissionGrants), and
#           group/directory-role memberships (memberOf) into join-by-AppId
#           row sets, mirroring Get-AppRegistration's Core+collections shape.
#           Every Graph call here is read-only (Get-Mg*), no writes.
# Params  : -Core  The Core array from Get-AppRegistration (supplies AppId +
#                  DisplayName without any extra Graph call).
# Returns : A PSCustomObject with ServicePrincipals/ServicePrincipalKeyCredentials/
#           ServicePrincipalPasswordCredentials/ServicePrincipalAppRoleAssignments/
#           ServicePrincipalOauth2PermissionGrants/ServicePrincipalMemberOf array
#           properties. Per-app/per-SP failures are isolated (warned, skipped)
#           rather than aborting the whole run -- most notably
#           oauth2PermissionGrants, which needs Directory.Read.All (broader
#           than the Application.Read.All this script otherwise requires; see
#           $script:OptionalAppRoleForDelegatedGrants above).
#-------------------------------------------------------------------------------
function Get-ServicePrincipalInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Core
    )

    # Top-level servicePrincipal properties needed for the ServicePrincipals
    # sheet plus its two credential collections. Raw key bytes/secret values
    # are never returned by a list call regardless of $select (same behavior
    # as the application resource, confirmed in the 2026-07-09 LEARNINGS entry).
    # NOTE: unlike the application resource, servicePrincipal has no
    # createdDateTime property on either the Graph REST resource or the
    # deserialized Microsoft.Graph.PowerShell.Models.MicrosoftGraphServicePrincipal
    # .NET type (verified via GetProperties() during live testing) -- omitted here.
    $spSelectProperties = @(
        'id'
        'appId'
        'displayName'
        'appDisplayName'
        'servicePrincipalType'
        'accountEnabled'
        'appOwnerOrganizationId'
        'signInAudience'
        'tags'
        'keyCredentials'
        'passwordCredentials'
    )

    $servicePrincipals              = [System.Collections.Generic.List[object]]::new()
    $spKeyCredentials               = [System.Collections.Generic.List[object]]::new()
    $spPasswordCredentials          = [System.Collections.Generic.List[object]]::new()
    $spAppRoleAssignments           = [System.Collections.Generic.List[object]]::new()
    $spOauth2PermissionGrants       = [System.Collections.Generic.List[object]]::new()
    $spMemberOf                     = [System.Collections.Generic.List[object]]::new()

    $warnedOnOauth2Scope = $false
    $index = 0
    $total = @($Core).Count

    foreach ($appRow in @($Core)) {
        $index++
        Write-Progress -Activity 'Collecting service principal inventory' `
            -Status "$index of $total`: $($appRow.DisplayName)" `
            -PercentComplete (($index / [math]::Max($total, 1)) * 100)

        try {
            $sp = @(Get-MgServicePrincipal -Filter "appId eq '$($appRow.AppId)'" -Property $spSelectProperties -All)
        }
        catch {
            Write-Warning "Failed to retrieve service principal for AppId '$($appRow.AppId)' ('$($appRow.DisplayName)'): $($_.Exception.Message)"
            continue
        }

        if ($sp.Count -eq 0) {
            Write-Warning "No service principal found for AppId '$($appRow.AppId)' ('$($appRow.DisplayName)') -- app registration may not be consented/instantiated in this tenant. Skipping."
            continue
        }

        foreach ($principal in $sp) {
            $servicePrincipals.Add([pscustomobject][ordered]@{
                AppId                  = $principal.AppId
                DisplayName            = $principal.DisplayName
                Id                     = $principal.Id
                ServicePrincipalType   = $principal.ServicePrincipalType
                AccountEnabled         = $principal.AccountEnabled
                AppOwnerOrganizationId = $principal.AppOwnerOrganizationId
                SignInAudience         = $principal.SignInAudience
                Tags                   = if ($principal.Tags) { $principal.Tags -join '; ' } else { '' }
            })

            foreach ($key in @($principal.KeyCredentials)) {
                if ($null -eq $key) { continue }
                $spKeyCredentials.Add([pscustomobject][ordered]@{
                    AppId                 = $principal.AppId
                    DisplayName           = $principal.DisplayName
                    KeyId                 = $key.KeyId
                    CredentialDisplayName = $key.DisplayName
                    Type                  = $key.Type
                    Usage                 = $key.Usage
                    StartDateTime         = $key.StartDateTime
                    EndDateTime           = $key.EndDateTime
                    ExpiryStatus          = Get-IamScoutExpiryStatus -EndDateTime $key.EndDateTime
                })
            }

            foreach ($pwdCred in @($principal.PasswordCredentials)) {
                if ($null -eq $pwdCred) { continue }
                $spPasswordCredentials.Add([pscustomobject][ordered]@{
                    AppId                 = $principal.AppId
                    DisplayName           = $principal.DisplayName
                    KeyId                 = $pwdCred.KeyId
                    CredentialDisplayName = $pwdCred.DisplayName
                    Hint                  = $pwdCred.Hint
                    StartDateTime         = $pwdCred.StartDateTime
                    EndDateTime           = $pwdCred.EndDateTime
                    ExpiryStatus          = Get-IamScoutExpiryStatus -EndDateTime $pwdCred.EndDateTime
                })
            }

            try {
                $assignments = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principal.Id -All)
                foreach ($assignment in $assignments) {
                    $spAppRoleAssignments.Add([pscustomobject][ordered]@{
                        AppId                = $principal.AppId
                        DisplayName          = $principal.DisplayName
                        AppRoleId            = $assignment.AppRoleId
                        PrincipalDisplayName = $assignment.PrincipalDisplayName
                        ResourceDisplayName  = $assignment.ResourceDisplayName
                        ResourceId           = $assignment.ResourceId
                        CreatedDateTime      = $assignment.CreatedDateTime
                    })
                }
            }
            catch {
                Write-Warning "Failed to retrieve app role assignments for service principal '$($principal.DisplayName)' ($($principal.Id)): $($_.Exception.Message)"
            }

            try {
                $grants = @(Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $principal.Id -All)
                foreach ($grant in $grants) {
                    $spOauth2PermissionGrants.Add([pscustomobject][ordered]@{
                        AppId       = $principal.AppId
                        DisplayName = $principal.DisplayName
                        ConsentType = $grant.ConsentType
                        PrincipalId = $grant.PrincipalId
                        ResourceId  = $grant.ResourceId
                        Scope       = $grant.Scope
                    })
                }
            }
            catch {
                if (-not $warnedOnOauth2Scope) {
                    Write-Warning "Failed to retrieve delegated permission grants (requires '$script:OptionalAppRoleForDelegatedGrants', broader than '$script:RequiredAppRole') -- leaving ServicePrincipalOauth2PermissionGrants empty for affected service principals. First error: $($_.Exception.Message)"
                    $warnedOnOauth2Scope = $true
                }
            }

            try {
                $memberships = @(Get-MgServicePrincipalMemberOf -ServicePrincipalId $principal.Id -All)
                foreach ($membership in $memberships) {
                    $memberType = if ($membership.AdditionalProperties -and $membership.AdditionalProperties['@odata.type']) {
                        ($membership.AdditionalProperties['@odata.type'] -replace '^#microsoft\.graph\.', '')
                    } else {
                        ''
                    }
                    $memberDisplayName = if ($membership.AdditionalProperties -and $membership.AdditionalProperties['displayName']) {
                        $membership.AdditionalProperties['displayName']
                    } else {
                        ''
                    }
                    $spMemberOf.Add([pscustomobject][ordered]@{
                        AppId          = $principal.AppId
                        DisplayName    = $principal.DisplayName
                        Id             = $membership.Id
                        MemberType     = $memberType
                        MemberDisplayName = $memberDisplayName
                    })
                }
            }
            catch {
                Write-Warning "Failed to retrieve group/directory-role memberships for service principal '$($principal.DisplayName)' ($($principal.Id)): $($_.Exception.Message)"
            }
        }
    }

    Write-Progress -Activity 'Collecting service principal inventory' -Completed

    return [pscustomobject]@{
        ServicePrincipals                      = $servicePrincipals.ToArray()
        ServicePrincipalKeyCredentials          = $spKeyCredentials.ToArray()
        ServicePrincipalPasswordCredentials     = $spPasswordCredentials.ToArray()
        ServicePrincipalAppRoleAssignments       = $spAppRoleAssignments.ToArray()
        ServicePrincipalOauth2PermissionGrants   = $spOauth2PermissionGrants.ToArray()
        ServicePrincipalMemberOf                 = $spMemberOf.ToArray()
    }
}


#-------------------------------------------------------------------------------
# Export-AppRegistration
#
# Purpose : Write the collected app-registration and service-principal data to
#           a single timestamped .xlsx workbook as multiple worksheets: a
#           "Core" sheet (one row per app) and a "ServicePrincipals" sheet
#           (one row per resolved SP) plus one sheet per multi-value
#           collection, each joined back via an AppId column. Collection
#           sheets are only written when they contain rows -- Export-Excel
#           requires at least one row per worksheet -- but Core and
#           ServicePrincipals are always written when present.
# Params  : -Data                 The object returned by Get-AppRegistration
#                                 (Core/RedirectUris/RequiredResourceAccess/
#                                 KeyCredentials/PasswordCredentials/AppRoles/
#                                 Oauth2PermissionScopes array properties).
#           -ServicePrincipalData The object returned by
#                                 Get-ServicePrincipalInventory.
#           -OutputDirectory      Folder to write the workbook into.
# Returns : The full path of the .xlsx file that was written. Throws on failure.
#-------------------------------------------------------------------------------
function Export-AppRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Data,

        [Parameter(Mandatory)]
        [pscustomobject] $ServicePrincipalData,

        [Parameter(Mandatory)]
        [string] $OutputDirectory
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $fileName  = "EntraAppRegistrations_$timestamp.xlsx"
    $fullPath  = Join-Path -Path $OutputDirectory -ChildPath $fileName

    $sheets = @(
        @{ Name = 'Core';                   Table = 'Core';                   Records = $Data.Core }
        @{ Name = 'RedirectUris';            Table = 'RedirectUris';            Records = $Data.RedirectUris }
        @{ Name = 'RequiredResourceAccess';  Table = 'RequiredResourceAccess';  Records = $Data.RequiredResourceAccess }
        @{ Name = 'KeyCredentials';          Table = 'KeyCredentials';          Records = $Data.KeyCredentials }
        @{ Name = 'PasswordCredentials';     Table = 'PasswordCredentials';     Records = $Data.PasswordCredentials }
        @{ Name = 'AppRoles';                Table = 'AppRoles';                Records = $Data.AppRoles }
        @{ Name = 'Oauth2PermissionScopes';  Table = 'Oauth2PermissionScopes';  Records = $Data.Oauth2PermissionScopes }
        # Worksheet names are capped at 31 characters by Excel (ImportExcel
        # silently truncates -- and warns -- past that), so the longer
        # ServicePrincipal* collection names below are shortened to an "SP"
        # prefix here. The underlying $ServicePrincipalData property names
        # stay fully spelled out; only the sheet/table labels are abbreviated.
        @{ Name = 'ServicePrincipals';         Table = 'ServicePrincipals';         Records = $ServicePrincipalData.ServicePrincipals }
        @{ Name = 'SPKeyCredentials';          Table = 'SPKeyCredentials';          Records = $ServicePrincipalData.ServicePrincipalKeyCredentials }
        @{ Name = 'SPPasswordCredentials';     Table = 'SPPasswordCredentials';     Records = $ServicePrincipalData.ServicePrincipalPasswordCredentials }
        @{ Name = 'SPAppRoleAssignments';      Table = 'SPAppRoleAssignments';      Records = $ServicePrincipalData.ServicePrincipalAppRoleAssignments }
        @{ Name = 'SPOauth2PermissionGrants';  Table = 'SPOauth2PermissionGrants';  Records = $ServicePrincipalData.ServicePrincipalOauth2PermissionGrants }
        @{ Name = 'SPMemberOf';                Table = 'SPMemberOf';                Records = $ServicePrincipalData.ServicePrincipalMemberOf }
    )

    try {
        foreach ($sheet in $sheets) {
            $rows = @($sheet.Records)
            if ($rows.Count -eq 0) {
                # Core is always written even for a 0-app tenant (Main guards that
                # case separately). Every other sheet -- including ServicePrincipals,
                # which can legitimately be empty even when Core has rows, e.g. a
                # tenant where no app registration has been consented into an SP --
                # is a joined collection and is omitted entirely rather than writing
                # a headerless sheet (Export-Excel requires at least one row).
                if ($sheet.Name -ne 'Core') { continue }
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
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Applications   -ErrorAction Stop
    Import-Module ImportExcel                    -ErrorAction Stop

    Connect-IamScoutGraph -TenantId $TenantId -ClientId $ClientId -ResetCredential:$ResetCredential
    $connected = $true

    $appData = Get-AppRegistration -IncludeOwners:$IncludeOwners

    if (@($appData.Core).Count -eq 0) {
        Write-Warning "No app registrations found in this tenant. Nothing to export."
    }
    else {
        Write-Host "Retrieving service principal inventory..." -ForegroundColor Cyan
        $spData = Get-ServicePrincipalInventory -Core $appData.Core

        $outputFile = Export-AppRegistration -Data $appData -ServicePrincipalData $spData -OutputDirectory $OutputDirectory
        Write-Host "Exported $(@($appData.Core).Count) app registration(s) and $(@($spData.ServicePrincipals).Count) service principal(s) to:" -ForegroundColor Green
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
