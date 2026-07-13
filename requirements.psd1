@{
    # Required PowerShell Gallery modules for the EntraID/PowerShell track.
    # Install with:
    #   Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.SignIns, ImportExcel -Scope CurrentUser
    # Version numbers are unpinned for now — pin once a known-good combination
    # has been verified in a working environment (see docs/LEARNINGS.md if this changes).
    RequiredModules = @(
        'Microsoft.Graph.Authentication'
        'Microsoft.Graph.Applications'
        'Microsoft.Graph.Users'
        'Microsoft.Graph.Identity.DirectoryManagement'
        'Microsoft.Graph.Identity.SignIns'
        'ImportExcel'
    )
}
