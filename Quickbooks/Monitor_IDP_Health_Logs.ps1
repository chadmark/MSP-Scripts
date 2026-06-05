<#
.SYNOPSIS
    Monitors Intuit Data Protect (IDP) service health and QuickBooks backup status via log parsing.

.DESCRIPTION
    Runs as a scheduled task (every 4 hours) to detect backup failures before the next scheduled
    backup cycle. Parses IBuEngHost.log directly since IDP does not expose backup status via API
    or exit codes accessible to external tools.

    HOW IT WORKS:
    IDP logs backup activity to IBuEngHost.log in an unbounded format (no rotation). Each successful
    backup cycle writes a line ending in "RunBackup_ElevateShadowCopyOnly returned: 0". The script
    searches the entire log for all occurrences of this pattern, parses the timestamp from each
    matching line using [regex]::Match() and [datetime]::ParseExact(), stores results as
    PSCustomObjects (required for correct Sort-Object behavior in PowerShell 5.1), then selects
    the most recent success and compares it against the configured SLA window.

    Note: IDP logs at the fileset level ("QuickBooks Desktop Data"), not per .qbw file. The
    $qbFilesToMonitor array supports multiple entries for display and SLA purposes, but all entries
    share the same backup timestamp since IDP backs up the entire fileset as one operation.

    HEALTH CHECKS (in order):
    1. QBVSS service running
    2. IBuEngHost.log reachable and low error/warning count in recent window
    3. Last successful backup within SLA hours for each configured QB file
    4. Optional: last entry from custom health check log

    ALERT BEHAVIOR:
    Sends an HTML-formatted email via SMTP when any health check fails. Severity escalates to
    CRITICAL when 2 or more issues are detected simultaneously. Use -TestMode to suppress email
    and print findings to the console instead.

.NOTES
    Author        : Chad
    Last Edit     : 06-04-2026
    GitHub        : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/Monitor_IDP_Health_Logs.ps1
    Environment   : Windows Server (Scheduled Task, every 4 hours)
    Requires      : PowerShell 5.1+, SMTP relay access
    Version       : 1.1
    Ninja Note    : Script Variables (4-space indent)
        $emailSmtpServer        | Calculated | String   | SMTP server (e.g., mail.authsmtp.com)
        $emailSmtpPort          | Calculated | String   | SMTP port (typically 587 for TLS)
        $emailFrom              | Calculated | String   | Sender email address
        $emailDisplayName       | Calculated | String   | Display name for emails
        $emailTo                | Calculated | String   | Recipient(s), comma-separated
        $emailUsername          | Calculated | String   | SMTP auth username
        $emailPassword          | Calculated | String   | SMTP auth password
        $idpLogPath             | Calculated | String   | Path to IBuEngHost.log (see Intuit docs)
        $healthCheckLogPath     | Calculated | String   | Path to idp_health_check.log (custom monitoring log)
        $qbFilesToMonitor       | Calculated | Array    | Array of QB files: @( @{ DisplayName = ""; FilePath = ""; SlaHours = 26 } )
        $logCheckWindowMinutes   | Calculated | String   | Minutes of log history to scan (e.g., 360 = 6 hours)
        $alertThrottleMinutes    | Calculated | String   | Min minutes between duplicate alerts (e.g., 60)

.CHANGELOG
    1.1 - 06-04-2026 - Added -SendTestAlert switch; sends a SUCCESS-severity test email to verify SMTP config without running health checks
    1.0 - 06-04-2026 - Initial stable release
.LINK
    https://github.com/chadmark/MSP-Scripts

#>

[CmdletBinding()]
param(
    [switch]$TestMode,
    [switch]$SendTestAlert
)

# ============================================================
# CONFIGURATION
# ============================================================

# EMAIL SETTINGS
$emailSmtpServer  = "mail.server.com"
$emailSmtpPort    = 587
$emailFrom        = "qbhealth@msp.com"
$emailDisplayName = "QB Health Monitor"
$emailTo          = "support@msp.com"
$emailUsername    = ""
$emailPassword    = ""

# IDP LOG PATHS
# Confirmed log path (no logs\ subfolder):
$idpLogPath         = "C:\ProgramData\Intuit\Intuit Data Protect\IBuEngHost.log"
$healthCheckLogPath = "C:\QBBackup\idp_health_check.log"

# QUICKBOOKS FILES TO MONITOR (supports multiple)
# Format: @{ DisplayName = "path\to\file.qbw"; SlaHours = 26 }
$qbFilesToMonitor = @(
    @{ DisplayName = "Client Company Name"; FilePath = "C:\path\to\company.qbw"; SlaHours = 26 }
    # Add more files as needed:
    # @{ DisplayName = "Second Company"; FilePath = "C:\path\to\second.qbw"; SlaHours = 26 }
)

# MONITORING SETTINGS
$logCheckWindowMinutes = 360         # Scan this many minutes of log history (6 hours)
$alertThrottleMinutes  = 60          # Don't send duplicate alerts more than once per hour

# IDP service name
$idpServiceName = "QBVSS"

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "[$timestamp] [$Level] $Message"
    Add-Content $healthCheckLogPath -Value $logEntry -Force

    switch ($Level) {
        'Error'   { Write-Host $logEntry -ForegroundColor Red }
        'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
        'Success' { Write-Host $logEntry -ForegroundColor Green }
        'Info'    { Write-Host $logEntry -ForegroundColor Cyan }
    }
}

function Send-HealthAlert {
    param(
        [string]$AlertTitle,
        [string]$AlertSeverity = 'WARNING',  # SUCCESS, WARNING, CRITICAL
        [hashtable]$Findings = @{}
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $hostname  = $env:COMPUTERNAME

    $findingsHtml = ""
    foreach ($key in $Findings.Keys) {
        $value = $Findings[$key]
        $findingsHtml += "<tr><td style='padding: 8px; border-bottom: 1px solid #ddd;'><strong>$key</strong></td><td style='padding: 8px; border-bottom: 1px solid #ddd;'>$value</td></tr>"
    }

    $severityColor = switch ($AlertSeverity) {
        'SUCCESS'  { '#27AE60' }
        'WARNING'  { '#E67E22' }
        'CRITICAL' { '#C0392B' }
        default    { '#34495E' }
    }

    $htmlBody = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; background-color: #f5f5f5; }
        .container { max-width: 600px; margin: 20px auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .header { background-color: $severityColor; color: white; padding: 15px; border-radius: 4px; margin-bottom: 20px; }
        .header h2 { margin: 0; font-size: 18px; }
        .header p { margin: 5px 0 0 0; font-size: 13px; }
        table { width: 100%; border-collapse: collapse; }
        td { padding: 8px; border-bottom: 1px solid #ddd; }
        strong { color: #2c3e50; }
        .footer { margin-top: 20px; font-size: 12px; color: #7f8c8d; border-top: 1px solid #ecf0f1; padding-top: 10px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>$AlertTitle</h2>
            <p>Severity: <strong>$AlertSeverity</strong> | Generated: $timestamp</p>
        </div>
        <table>
            $findingsHtml
        </table>
        <div class="footer">
            <p><strong>Markley Technologies - QuickBooks Health Monitoring</strong></p>
            <p>Host: $hostname | Service: Intuit Data Protect (QBVSS)</p>
        </div>
    </div>
</body>
</html>
"@

    if ($TestMode) {
        Write-Host "`n[TEST MODE] Email suppressed. Would have sent:" -ForegroundColor Magenta
        Write-Host "  Subject  : [$AlertSeverity] $AlertTitle" -ForegroundColor Cyan
        Write-Host "  To       : $emailTo" -ForegroundColor Cyan
        Write-Host "  Findings :" -ForegroundColor Cyan
        foreach ($key in $Findings.Keys) {
            Write-Host "    $key : $($Findings[$key])" -ForegroundColor Gray
        }
        Write-Host ""
    } else {
        try {
            $mailParams = @{
                SmtpServer    = $emailSmtpServer
                Port          = $emailSmtpPort
                From          = "$emailDisplayName <$emailFrom>"
                To            = $emailTo
                Subject       = "[$AlertSeverity] $AlertTitle"
                Body          = $htmlBody
                BodyAsHtml    = $true
                Credential    = (New-Object System.Management.Automation.PSCredential($emailUsername, (ConvertTo-SecureString $emailPassword -AsPlainText -Force)))
                UseSsl        = $true
                ErrorAction   = 'Stop'
            }
            Send-MailMessage @mailParams
            Write-Log "Alert email sent: $AlertTitle" 'Success'
        } catch {
            Write-Log "Failed to send alert email: $($_.Exception.Message)" 'Error'
        }
    }
}

function Get-IDPServiceHealth {
    try {
        $svc = Get-Service -Name $idpServiceName -ErrorAction Stop
        return @{
            Running = $svc.Status -eq 'Running'
            Status  = $svc.Status
            Error   = $null
        }
    } catch {
        return @{
            Running = $false
            Status  = 'NotFound'
            Error   = $_.Exception.Message
        }
    }
}

function Get-BackupStatusForAllFiles {
    param([string]$LogPath, [array]$QBFiles)

    $backupStatus = @{}

    if (-not (Test-Path $LogPath)) {
        foreach ($file in $QBFiles) {
            $backupStatus[$file.DisplayName] = @{
                Success            = $false
                LastBackupTime     = $null
                HoursSinceBackup   = "N/A"
                Status             = "LOG_NOT_FOUND"
                Error              = "Log file not found: $LogPath"
            }
        }
        return $backupStatus
    }

    try {
        $content = Get-Content $LogPath -ErrorAction Stop
        
        # Parse all log lines and extract timestamps
        # Look for patterns like: [2024-05-19 14:30:45] [Info] ... backup complete for C:\path\to\file.qbw
        $logEntries = @()
        foreach ($line in $content) {
            $logEntries += @{ Line = $line }
        }

        foreach ($qbFile in $QBFiles) {
            $fileName        = Split-Path $qbFile.FilePath -Leaf
            $fileNameEscaped = [regex]::Escape($fileName)

            # Find all backup-related entries for this specific file
            $fileMatches = $logEntries | Where-Object {
                $_.Line -match $fileNameEscaped -or $_.Line -match [regex]::Escape($qbFile.FilePath)
            }

            # Match the confirmed success pattern from IBuEngHost.log:
            # 2026-01-19 22:48:55.732 (IBuEngHost.SymantecBackup.RunBackup_ElevateShadowCopyOnly): RunBackup_ElevateShadowCopyOnly returned: 0
            # Timestamp format: YYYY-MM-DD HH:mm:ss.fff (no brackets)
            $successMatches = @()
            foreach ($entry in $fileMatches) {
                if ($entry.Line -match 'returned:\s*0') {
                    $m = [regex]::Match($entry.Line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
                    if ($m.Success) {
                        try {
                            $successMatches += [PSCustomObject]@{ Time = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null); Line = $entry.Line }
                        } catch {
                            # Timestamp parse error, skip
                        }
                    }
                }
            }

            # Also search entire log for returned: 0 if no file-specific matches
            # (IDP does not log the individual .qbw filename - it logs at fileset level only)
            if ($successMatches.Count -eq 0) {
                foreach ($entry in $logEntries) {
                    if ($entry.Line -match 'RunBackup_ElevateShadowCopyOnly returned:\s*0') {
                        $m = [regex]::Match($entry.Line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
                        if ($m.Success) {
                            try {
                                $successMatches += [PSCustomObject]@{ Time = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null); Line = $entry.Line }
                            } catch {
                                # Timestamp parse error, skip
                            }
                        }
                    }
                }
            }

            if ($successMatches.Count -gt 0) {
                $lastSuccess = $successMatches | Sort-Object -Property Time -Descending | Select-Object -First 1
                $lastBackupTime = $lastSuccess.Time
                $hoursSince = [math]::Round(((Get-Date) - $lastBackupTime).TotalHours, 2)
                $isHealthy = $hoursSince -le $qbFile.SlaHours

                $backupStatus[$qbFile.DisplayName] = @{
                    Success          = $true
                    LastBackupTime   = $lastBackupTime.ToString("yyyy-MM-dd HH:mm:ss")
                    HoursSinceBackup = $hoursSince
                    SlaHours         = $qbFile.SlaHours
                    IsWithinSla      = $isHealthy
                    Status           = if ($isHealthy) { "HEALTHY" } else { "STALE" }
                    Error            = $null
                }
            } else {
                # No successful backup found in logs
                $backupStatus[$qbFile.DisplayName] = @{
                    Success          = $false
                    LastBackupTime   = $null
                    HoursSinceBackup = "Unknown"
                    SlaHours         = $qbFile.SlaHours
                    IsWithinSla      = $false
                    Status           = "NO_SUCCESS_FOUND"
                    Error            = "No successful backup detected in logs"
                }
            }
        }

        return $backupStatus
    } catch {
        foreach ($file in $QBFiles) {
            $backupStatus[$file.DisplayName] = @{
                Success          = $false
                LastBackupTime   = $null
                HoursSinceBackup = "N/A"
                Status           = "LOG_PARSE_ERROR"
                Error            = $_.Exception.Message
            }
        }
        return $backupStatus
    }
}

function Get-LogErrorCount {
    param([string]$LogPath, [int]$MinutesBack = 360)

    if (-not (Test-Path $LogPath)) {
        return @{
            ErrorCount   = 0
            WarningCount = 0
            CriticalWords = @()
        }
    }

    try {
        $cutoffTime = (Get-Date).AddMinutes(-$MinutesBack)
        $content    = Get-Content $LogPath -ErrorAction Stop

        # Simple time-aware filter: assume log lines start with timestamps
        $recentLines = $content | Where-Object {
            try {
                $firstBracket = $_ -match '\[(.+?)\]'
                if ($matches) {
                    [datetime]$lineTime = $matches[1]
                    $lineTime -gt $cutoffTime
                } else {
                    $true  # Include if no timestamp (be conservative)
                }
            } catch {
                $true  # Include on parse error
            }
        }

        $errorCount   = ($recentLines | Select-String -Pattern '\[Error\]|\[CRITICAL\]' -AllMatches).Count
        $warningCount = ($recentLines | Select-String -Pattern '\[Warning\]|\[WARN\]' -AllMatches).Count
        $criticalWords = @()

        $criticalPatterns = @(
            'Unauthorized|Authentication Failed|Permission Denied',
            'Disk Full|Out of Space|Storage Error',
            'Service Crashed|Unhandled Exception|Fatal Error'
        )

        foreach ($pattern in $criticalPatterns) {
            if ($recentLines | Select-String -Pattern $pattern) {
                $criticalWords += $pattern
            }
        }

        return @{
            ErrorCount   = $errorCount
            WarningCount = $warningCount
            CriticalWords = $criticalWords
        }
    } catch {
        Write-Log "Error analyzing log: $($_.Exception.Message)" 'Warning'
        return @{
            ErrorCount   = 0
            WarningCount = 0
            CriticalWords = @('LOG_PARSE_ERROR')
        }
    }
}

# ============================================================
# SEND TEST ALERT (runs before health checks; requires functions defined above)
# ============================================================

if ($SendTestAlert) {
    Write-Log "SendTestAlert: sending test email to verify SMTP configuration..." 'Info'
    Send-HealthAlert `
        -AlertTitle "Test Alert - Email Configuration Verified" `
        -AlertSeverity "SUCCESS" `
        -Findings @{
            'Test'     = 'This is a test alert to verify SMTP configuration'
            'Host'     = $env:COMPUTERNAME
            'Script'   = $MyInvocation.MyCommand.Name
            'Time'     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
    Write-Log "Test alert sent. Check inbox at: $emailTo" 'Success'
    exit 0
}

# ============================================================
# MAIN HEALTH CHECK LOGIC
# ============================================================

Write-Log "====== IDP Health Check Started ======" 'Info'

$healthIssues = @()
$findings      = @{}

# ---- CHECK 1: Service Status ----
Write-Log "Checking service status..." 'Info'
$svcHealth = Get-IDPServiceHealth

$findings['Service Name'] = $idpServiceName
$findings['Service Status'] = $svcHealth.Status

if (-not $svcHealth.Running) {
    $healthIssues += "IDP service is not running (Status: $($svcHealth.Status))"
    Write-Log "ALERT: Service not running" 'Error'
} else {
    Write-Log "Service is running" 'Success'
}

# ---- CHECK 2: Log File Health ----
Write-Log "Analyzing log files..." 'Info'

if (-not (Test-Path $idpLogPath)) {
    $healthIssues += "IBuEngHost.log not found at $idpLogPath"
    $findings['IBuEngHost.log'] = "NOT FOUND"
    Write-Log "ALERT: Log file not found at $idpLogPath" 'Error'
} else {
    $logHealth = Get-LogErrorCount -LogPath $idpLogPath -MinutesBack $logCheckWindowMinutes
    
    $findings['Errors (Last 6h)'] = $logHealth.ErrorCount
    $findings['Warnings (Last 6h)'] = $logHealth.WarningCount

    if ($logHealth.ErrorCount -ge 5) {
        $healthIssues += "High error count in log: $($logHealth.ErrorCount) errors in last $logCheckWindowMinutes minutes"
        Write-Log "ALERT: High error count detected" 'Warning'
    }

    if ($logHealth.CriticalWords.Count -gt 0) {
        $healthIssues += "Critical patterns detected: $($logHealth.CriticalWords -join ', ')"
        Write-Log "ALERT: Critical patterns in logs: $($logHealth.CriticalWords -join ', ')" 'Error'
    }
}

# ---- CHECK 3: QB File Backup Status ----
Write-Log "Checking backup status for QuickBooks files..." 'Info'

$backupStatusAll = Get-BackupStatusForAllFiles -LogPath $idpLogPath -QBFiles $qbFilesToMonitor

foreach ($qbFile in $qbFilesToMonitor) {
    $displayName = $qbFile.DisplayName
    $status      = $backupStatusAll[$displayName]

    Write-Log "[$displayName] Status: $($status.Status)" 'Info'

    # Add to findings with detailed backup info
    if ($status.Success) {
        $lastBackupStr = "$($status.LastBackupTime) ($([math]::Round($status.HoursSinceBackup, 1)) hours ago)"
        $findings["$displayName - Last Backup"] = $lastBackupStr
        $findings["$displayName - SLA"] = "$($qbFile.SlaHours) hours"
        $findings["$displayName - Health"] = $status.Status
        
        if (-not $status.IsWithinSla) {
            $healthIssues += "$displayName backup is stale: last backup $([math]::Round($status.HoursSinceBackup, 1)) hours ago (SLA: $($qbFile.SlaHours) hours)"
            Write-Log "ALERT: $displayName backup exceeds SLA" 'Warning'
        }
    } else {
        $findings["$displayName - Last Backup"] = "UNKNOWN (no success found in logs)"
        $findings["$displayName - SLA"] = "$($qbFile.SlaHours) hours"
        $findings["$displayName - Health"] = $status.Status
        $findings["$displayName - Error"] = $status.Error
        
        $healthIssues += "${displayName}: $($status.Error)"
        Write-Log "ALERT: $displayName backup status unknown or failed" 'Error'
    }
}

# ---- CHECK 4: Health Check Log ----
Write-Log "Checking custom health log..." 'Info'

if (Test-Path $healthCheckLogPath) {
    $lastLine = Get-Content $healthCheckLogPath -Tail 1 -ErrorAction SilentlyContinue
    $findings['Last Custom Health Log'] = $lastLine
}

# ---- DECIDE ON ALERT ----
if ($healthIssues.Count -gt 0) {
    Write-Log "Health issues detected: $($healthIssues -join '; ')" 'Warning'

    $findings['Total Issues'] = $healthIssues.Count
    $findings['Details'] = ($healthIssues -join '<br/>')

    $severity = if ($healthIssues.Count -ge 2) { 'CRITICAL' } else { 'WARNING' }

    Send-HealthAlert `
        -AlertTitle "Intuit Data Protect Unhealthy ($($healthIssues.Count) issue$(if ($healthIssues.Count -ne 1) {'s'}))" `
        -AlertSeverity $severity `
        -Findings $findings

    Write-Log "====== IDP Health Check COMPLETED: ALERT SENT ======" 'Warning'
    exit 1
} else {
    Write-Log "All health checks passed" 'Success'
    Write-Log "====== IDP Health Check COMPLETED: HEALTHY ======" 'Success'
    exit 0
}