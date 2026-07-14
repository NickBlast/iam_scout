#Requires -Version 7.0
<#
================================================================================
 iam-scout-syncmonitor-alerting

 SMTP alert dispatch for the Entra Connect sync health monitor, isolated from
 the detection logic (iam-scout-syncmonitor-eventlog) so transport changes
 never touch polling code.

 WHY System.Net.Mail INSTEAD OF Send-MailMessage:
   Send-MailMessage is deprecated ("obsolete... does not guarantee secure
   connections") in PowerShell 7+. The target here is an internal
   unauthenticated relay, so the .NET SmtpClient is used directly:
   no credentials, no SSL, plain port-25-style relay submission.
================================================================================
#>

Set-StrictMode -Version Latest

#-------------------------------------------------------------------------------
# Send-IamScoutSyncAlert
#
# Purpose : Send one plain-text alert email via the internal SMTP relay
#           (unauthenticated). All connection settings come from the caller's
#           config -- nothing is hardcoded here.
# Params  : -SmtpServer / -Port  Relay host and port.
#           -From / -To          Sender and one or more recipients.
#           -Subject / -Body     Message content (plain text).
# Returns : Nothing. Throws with a readable message if the relay rejects or
#           is unreachable -- the caller decides whether that is fatal.
#-------------------------------------------------------------------------------
function Send-IamScoutSyncAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SmtpServer,

        [Parameter(Mandatory)]
        [int] $Port,

        [Parameter(Mandatory)]
        [string] $From,

        [Parameter(Mandatory)]
        [string[]] $To,

        [Parameter(Mandatory)]
        [string] $Subject,

        [Parameter(Mandatory)]
        [string] $Body
    )

    $message = [System.Net.Mail.MailMessage]::new()
    $client  = [System.Net.Mail.SmtpClient]::new($SmtpServer, $Port)

    try {
        $message.From = [System.Net.Mail.MailAddress]::new($From)
        foreach ($recipient in $To) {
            $message.To.Add($recipient)
        }
        $message.Subject    = $Subject
        $message.Body       = $Body
        $message.IsBodyHtml = $false

        # Internal relay: no authentication, no TLS negotiation forced.
        $client.UseDefaultCredentials = $false
        $client.EnableSsl             = $false
        $client.DeliveryMethod        = [System.Net.Mail.SmtpDeliveryMethod]::Network

        $client.Send($message)
    }
    catch {
        throw "Failed to send alert via SMTP relay '$SmtpServer`:$Port': $($_.Exception.Message)"
    }
    finally {
        $message.Dispose()
        $client.Dispose()
    }
}


Export-ModuleMember -Function @('Send-IamScoutSyncAlert')
