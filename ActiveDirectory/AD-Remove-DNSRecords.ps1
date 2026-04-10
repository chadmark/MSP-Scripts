<#
    .SYNOPSIS
    Remove stale DNS records for a decommissioned domain controller.

    .DESCRIPTION
    Identifies and removes DNS records matching the specified server hostname, FQDN,
    or IP address across all primary DNS zones. Displays matched records before removal.

    .NOTES
    Original Author: ALI TAJRAN
    Original Link:   https://www.alitajran.com/clean-up-dns-records-powershell/
    Author:          Chad Mark
    Last Edit:       04-10-2026
    GitHub:          https://github.com/chadmark/MSP-Scripts/blob/main/ActiveDirectory/AD-Remove-DNSRecords.ps1
    Environment:     DNS Server (run locally)
    Requires:        DnsServer PowerShell module
    Version:         1.0

    .LINK
    https://github.com/chadmark/MSP-Scripts
#>

$ServerFQDN     = "hdcdc.local.hdcco.net." # Keep the dot (.) at the end
$ServerHostname = "hdcdc"
$IPAddress      = "10.1.1.76"
$WhatIf         = $true  # Set to $false to actually delete

$Zones = Get-DnsServerZone | Where-Object { $_.ZoneType -eq "Primary" } |
    Select-Object -ExpandProperty ZoneName

$matched = @()

foreach ($Zone in $Zones) {
    $records = Get-DnsServerResourceRecord -ZoneName $Zone | Where-Object {
        $_.RecordData.IPv4Address   -eq $IPAddress    -or
        $_.RecordData.NameServer    -eq $ServerFQDN   -or
        $_.RecordData.DomainName    -eq $ServerFQDN   -or
        $_.RecordData.HostnameAlias -eq $ServerFQDN   -or
        $_.RecordData.MailExchange  -eq $ServerFQDN   -or
        $_.HostName                 -eq $ServerHostname
    }

    foreach ($record in $records) {
        $matched += [PSCustomObject]@{
            Zone       = $Zone
            HostName   = $record.HostName
            RecordType = $record.RecordType
            RecordData = $record.RecordData.IPv4Address ??
                         $record.RecordData.NameServer ??
                         $record.RecordData.DomainName ??
                         $record.RecordData.HostnameAlias ??
                         $record.RecordData.MailExchange ??
                         "(see raw record)"
        }
    }
}

if ($matched.Count -eq 0) {
    Write-Host "No matching DNS records found." -ForegroundColor Green
} else {
    Write-Host "`nMatching DNS records found ($($matched.Count) total):" -ForegroundColor Yellow
    $matched | Format-Table -AutoSize

    if ($WhatIf) {
        Write-Host "WhatIf mode - no records deleted. Set `$WhatIf = `$false to remove." -ForegroundColor Cyan
    } else {
        foreach ($Zone in ($matched.Zone | Select-Object -Unique)) {
            Get-DnsServerResourceRecord -ZoneName $Zone | Where-Object {
                $_.RecordData.IPv4Address   -eq $IPAddress    -or
                $_.RecordData.NameServer    -eq $ServerFQDN   -or
                $_.RecordData.DomainName    -eq $ServerFQDN   -or
                $_.RecordData.HostnameAlias -eq $ServerFQDN   -or
                $_.RecordData.MailExchange  -eq $ServerFQDN   -or
                $_.HostName                 -eq $ServerHostname
            } | Remove-DnsServerResourceRecord -ZoneName $Zone -Force
        }
        Write-Host "Records removed." -ForegroundColor Red
    }
}
