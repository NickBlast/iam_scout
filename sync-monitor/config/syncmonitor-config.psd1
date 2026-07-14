# Local dev copy -- see syncmonitor-config.psd1.example for documentation.
@{
    StalenessThresholdMinutes = 45
    PollIntervalMinutes       = 5

    EventLog = @{
        LogName                 = 'Application'
        Providers               = @('ADSync', 'Directory Synchronization')
        Levels                  = @(1, 2)
        FirstRunLookbackMinutes = 60
    }

    Smtp = @{
        Server = '127.0.0.1'
        Port   = 2525
        From   = 'entra-sync-monitor@iamscout.local'
        To     = @('nlundquist@proton.me')
    }
}
