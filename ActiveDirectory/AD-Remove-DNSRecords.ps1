<#
    .SYNOPSIS
    Remove stale DNS records for a decommissioned domain controller.

    .DESCRIPTION
    Identifies and removes DNS records matching the specified server hostname, FQDN,
    or IP address across all primary DNS zones, both forward and reverse lookup zones.
    Displays matched records before removal.

    Record types matched:
        A       - RecordData.IPv4Address  = $IPAddress
        NS      - RecordData.NameServer   = $ServerFQDN  (forward and reverse zones)
        SRV     - RecordData.DomainName   = $ServerFQDN  (_ldap, _kerberos, _gc, etc.)
        CNAME   - RecordData.HostnameAlias = $ServerFQDN (<DSA-GUID>._msdcs alias)
        MX      - RecordData.MailExchange = $ServerFQDN
        PTR     - RecordData.PtrDomainName = $ServerFQDN (reverse lookup zones)
        Any     - HostName = $ServerHostname (forward zones only; in reverse zones
                  HostName is the IP octet, so PTRs are matched by PtrDomainName)

    NOT handled (review manually in DNS Manager):
        - SOA records: if the old DC is listed as Primary Server on any zone's SOA,
          change it to a surviving DC. The SOA is never deleted by this script.
        - AAAA records (IPv6). Only relevant if the old DC registered IPv6 addresses.
        - Secondary, stub, and conditional forwarder zones (only Primary zones scanned).

    Usage:
        1. Complete metadata cleanup for the old DC first (ntdsutil or ADUC/ADSS delete).
        2. Edit the four variables at the top of the script.
           - $ServerFQDN must end with a trailing dot (.)
        3. Run elevated on a DC with the DNS Server role, $WhatIf = $true. Review output.
        4. Set $WhatIf = $false and run again to delete.
        5. Changes to AD-integrated zones replicate to other DNS servers normally.
           Verify with: repadmin /syncall /AdeP, then dcdiag /test:dns

    .EXAMPLE
    # Dry run (default). Lists matches in forward and reverse zones, deletes nothing.
    $ServerFQDN     = "olddc01.corp.contoso.com."
    $ServerHostname = "olddc01"
    $IPAddress      = "10.1.1.76"
    $WhatIf         = $true
    .\AD-Remove-DNSRecords.ps1

    Sample output:
        Zone               HostName              RecordType RecordData
        ----               --------              ---------- ----------
        corp.contoso.com   olddc01               A          10.1.1.76
        corp.contoso.com   @                     NS         olddc01.corp.contoso.com.
        _msdcs.corp...     _ldap._tcp.dc         SRV        olddc01.corp.contoso.com.
        1.1.10.in-addr.arpa 76                   PTR        olddc01.corp.contoso.com.

    .EXAMPLE
    # Live removal after reviewing the dry run.
    $WhatIf = $false
    .\AD-Remove-DNSRecords.ps1

    .NOTES
    Original Author: ALI TAJRAN
    Original Link:   https://www.alitajran.com/clean-up-dns-records-powershell/
    Author:          Chad Mark
    Last Edit:       10-22-2026
    GitHub:          https://github.com/chadmark/MSP-Scripts/blob/main/ActiveDirectory/AD-Remove-DNSRecords.ps1
    Environment:     DNS Server / Domain Controller (run locally, elevated)
    Requires:        DnsServer PowerShell module; Windows PowerShell 5.1 or PowerShell 7+
    Version:         1.1

    .CHANGELOG
    1.0 - 04-10-2026 - Initial release
    1.1 - 10-22-2026 - Added PTR matching (PtrDomainName) for reverse lookup zones; replaced PS7-only ?? operator for Windows PowerShell 5.1 compatibility; consolidated duplicate match filter into one scriptblock; expanded header with usage, examples, and limitations

    .LINK
    https://github.com/chadmark/MSP-Scripts
#>

$ServerFQDN     = "hdcdc.local.hdcco.net." # Keep the dot (.) at the end
$ServerHostname = "hdcdc"
$IPAddress      = "10.1.1.76"
$WhatIf         = $true  # Set to $false to actually delete

# Single match filter used for both the report and the delete pass
$MatchFilter = {
    $_.RecordData.IPv4Address   -eq $IPAddress  -or
    $_.RecordData.NameServer    -eq $ServerFQDN -or
    $_.RecordData.DomainName    -eq $ServerFQDN -or
    $_.RecordData.HostnameAlias -eq $ServerFQDN -or
    $_.RecordData.MailExchange  -eq $ServerFQDN -or
    $_.RecordData.PtrDomainName -eq $ServerFQDN -or
    $_.HostName                 -eq $ServerHostname
}

# Returns the first populated RecordData value for display (PS 5.1 safe, no ?? operator)
function Get-RecordValue {
    param ($Record)
    foreach ($prop in 'IPv4Address','NameServer','DomainName','HostnameAlias','MailExchange','PtrDomainName') {
        $value = $Record.RecordData.$prop
        if ($null -ne $value -and "$value" -ne '') { return "$value" }
    }
    return "(see raw record)"
}

$Zones = Get-DnsServerZone | Where-Object { $_.ZoneType -eq "Primary" } |
    Select-Object -ExpandProperty ZoneName

$matched = @()

foreach ($Zone in $Zones) {
    $records = Get-DnsServerResourceRecord -ZoneName $Zone | Where-Object $MatchFilter

    foreach ($record in $records) {
        $matched += [PSCustomObject]@{
            Zone       = $Zone
            HostName   = $record.HostName
            RecordType = $record.RecordType
            RecordData = Get-RecordValue -Record $record
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
            Get-DnsServerResourceRecord -ZoneName $Zone |
                Where-Object $MatchFilter |
                Remove-DnsServerResourceRecord -ZoneName $Zone -Force
        }
        Write-Host "Records removed." -ForegroundColor Red
    }
}
