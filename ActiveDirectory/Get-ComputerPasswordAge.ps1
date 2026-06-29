<#
.SYNOPSIS
    Scans Active Directory for computer objects and reports the age of each machine's
    account password, which reflects the last time the device communicated with a DC.

.DESCRIPTION
    Queries AD for all computer objects (servers and workstations) and retrieves the
    PasswordLastSet attribute. Domain-joined machines rotate their machine account
    password automatically every ~30 days while online. A stale PasswordLastSet date
    is a reliable indicator that the device has not been online or domain-connected
    recently.

    Output is written to a tab-delimited log file and optionally printed to the console.
    Devices can be filtered by staleness threshold (days since last password set).

.NOTES
    Author:         Chad
    Last Edit:      06-29-2025
    GitHub:         chadmark/MSP-Scripts/ActiveDirectory/Get-ComputerPasswordAge.ps1
    Environment:    On-premises AD or hybrid — run from any domain-joined machine
                    or machine with RSAT installed, with AD read access.
    Requires:       ActiveDirectory module (RSAT: AD DS Tools)
    Version:        1.0

.CHANGELOG
    1.0 - 06-29-2025 - Initial release

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# ─── CONFIGURATION ────────────────────────────────────────────────────────────

# How many days since PasswordLastSet before a computer is flagged as stale.
# Set to 0 to include ALL computers regardless of age.
$StaleThresholdDays = 90

# Where to write the log file. Defaults to the script's directory.
$LogPath = Join-Path $PSScriptRoot "ComputerPasswordAge_$(Get-Date -Format 'yyyy-MM-dd').log"

# Print results to the console in addition to the log file.
$PrintToConsole = $true

# Filter by computer type. Options: "All", "Servers", "Workstations"
$Filter = "All"

# ─── SCRIPT ───────────────────────────────────────────────────────────────────

#Requires -Modules ActiveDirectory

$today      = Get-Date
$threshold  = if ($StaleThresholdDays -gt 0) { $today.AddDays(-$StaleThresholdDays) } else { [datetime]::MinValue }

Write-Host "`nQuerying Active Directory for computer objects..." -ForegroundColor Cyan

# Retrieve all enabled computer objects with the properties we need.
# OperatingSystem is used to distinguish servers from workstations.
$computers = Get-ADComputer -Filter { Enabled -eq $true } -Properties `
    Name, OperatingSystem, PasswordLastSet, DistinguishedName, Description |
    Sort-Object Name

# Apply type filter
$computers = switch ($Filter) {
    "Servers"      { $computers | Where-Object { $_.OperatingSystem -like "*Server*" } }
    "Workstations" { $computers | Where-Object { $_.OperatingSystem -notlike "*Server*" } }
    default        { $computers }
}

# Build result objects
$results = foreach ($computer in $computers) {
    $passwordLastSet = $computer.PasswordLastSet

    $daysSince = if ($passwordLastSet) {
        [math]::Round(($today - $passwordLastSet).TotalDays, 1)
    } else {
        $null
    }

    $isStale = if ($null -eq $daysSince) {
        $true  # Never set — treat as stale
    } elseif ($StaleThresholdDays -gt 0) {
        $daysSince -ge $StaleThresholdDays
    } else {
        $false
    }

    $type = if ($computer.OperatingSystem -like "*Server*") { "Server" } else { "Workstation" }

    [PSCustomObject]@{
        Name            = $computer.Name
        Type            = $type
        OperatingSystem = $computer.OperatingSystem
        PasswordLastSet = if ($passwordLastSet) { $passwordLastSet.ToString("MM/dd/yyyy HH:mm") } else { "Never" }
        DaysSince       = if ($null -ne $daysSince) { $daysSince } else { "N/A" }
        Stale           = $isStale
        Description     = $computer.Description
        OU              = ($computer.DistinguishedName -replace '^CN=[^,]+,', '')
    }
}

# Apply staleness filter to output (only if threshold is set)
$output = if ($StaleThresholdDays -gt 0) {
    $results | Where-Object { $_.Stale -eq $true }
} else {
    $results
}

# ─── CONSOLE OUTPUT ───────────────────────────────────────────────────────────

if ($PrintToConsole) {
    $output | Format-Table -AutoSize -Property Name, Type, OperatingSystem, PasswordLastSet, DaysSince, Stale
}

# ─── LOG FILE ─────────────────────────────────────────────────────────────────

$header = "# ComputerPasswordAge Report`n" +
          "# Generated:  $today`n" +
          "# Threshold:  $StaleThresholdDays days ($([int]($StaleThresholdDays/30)) months approx)`n" +
          "# Filter:     $Filter`n" +
          "# Total matching computers: $($output.Count) of $($results.Count) total`n" +
          "#`n"

$tsv = $output | ConvertTo-Csv -Delimiter "`t" -NoTypeInformation

$header + ($tsv -join "`n") | Out-File -FilePath $LogPath -Encoding UTF8

Write-Host "`nResults written to: $LogPath" -ForegroundColor Green
Write-Host "Total computers scanned : $($results.Count)"
Write-Host "Stale / matching output : $($output.Count)"

# ─── SUMMARY BREAKDOWN ────────────────────────────────────────────────────────

$staleServers      = ($output | Where-Object { $_.Type -eq "Server" }).Count
$staleWorkstations = ($output | Where-Object { $_.Type -eq "Workstation" }).Count

Write-Host "`nBreakdown of flagged computers:"
Write-Host "  Servers      : $staleServers"
Write-Host "  Workstations : $staleWorkstations`n"
