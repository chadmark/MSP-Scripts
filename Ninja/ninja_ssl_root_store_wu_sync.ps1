<#
.SYNOPSIS
    Audits (and optionally force-syncs) a device's local Trusted Root CA store against the Windows Update root catalog.

.DESCRIPTION
    Runs `certutil -generateSSTFromWU` to pull the current Microsoft-trusted root catalog, compares it
    against Cert:\LocalMachine\Root, and reports any roots present in the WU catalog but missing locally.

    Windows only auto-pulls a missing WU-trusted root the first time it's actually needed during a live
    TLS handshake - it does not proactively push new/changed roots. A server that's had a root cached
    since deployment (or that doesn't regularly negotiate TLS to sites using that specific root) can sit
    with stale trust info indefinitely. That's the exact failure mode behind the Norman's Nursery
    GoDaddy G2->R1 wildcard issue - a stale locally-cached GoDaddy root produced a Chrome-only trust
    failure while Edge/Firefox validated fine.

    Report-only mode just logs what's missing, with GoDaddy/Starfield roots called out specifically
    since that's the active transition (G2->R1, deadline June 15 2026). Non-report-only mode imports
    the missing roots into Cert:\LocalMachine\Root to force the sync proactively, ahead of the next
    cert renewal that could trip the same bug.

.NOTES
    Author:        Chad
    Last Edit:     09-15-2026
    GitHub Path:   MSP-Scripts/NinjaOne/ninja_ssl_root_store_wu_sync.ps1
    Environment:   Windows Server 2016+ / Windows 10+, run as SYSTEM via NinjaOne
    Requires:      Local admin, certutil.exe (built-in)
    Version:       1.0
    Ninja Note:    Variable "reportOnly" - Type: Check box
                       true  = audit only, no changes made
                       false = missing roots are imported into Cert:\LocalMachine\Root
                       DEFAULT VALUE MUST BE CHECKED (true). Unchecked is the remediate
                       branch - leaving it unchecked by default means any run that doesn't
                       explicitly set the value (scheduled policy, bulk "run on all devices")
                       imports roots instead of auditing first.
.CHANGELOG
    1.0 - 09-15-2026 - Confirmed working in field: audit branch and import branch both verified
                       across multiple servers. Reordered output so import RESULT prints before
                       the per-cert detail dump (Ninja activity pane truncates long output).
                       Removed debug diagnostic line used during troubleshooting.
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

$ErrorActionPreference = 'Stop'

$reportOnly = [System.Convert]::ToBoolean($env:reportOnly)

$sstPath = Join-Path $env:TEMP "wu_root_catalog_$(Get-Date -Format 'yyyyMMdd_HHmmss').sst"

try {
    Write-Output "Generating current WU root catalog snapshot..."
    $certutilOutput = & certutil.exe -generateSSTFromWU $sstPath 2>&1
    if (-not (Test-Path $sstPath)) {
        throw "certutil -generateSSTFromWU did not produce an SST file. Output: $certutilOutput"
    }

    # Load WU-trusted roots from the SST snapshot
    $wuCerts = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $wuCerts.Import($sstPath)

    # Load what's actually trusted locally right now
    $localRootCerts = Get-ChildItem -Path 'Cert:\LocalMachine\Root'
    $localThumbprints = $localRootCerts.Thumbprint

    $missingCerts = $wuCerts | Where-Object { $_.Thumbprint -notin $localThumbprints }

    Write-Output "WU catalog roots: $($wuCerts.Count)"
    Write-Output "Local Root store roots: $($localRootCerts.Count)"
    Write-Output "Missing locally: $($missingCerts.Count)"

    if ($missingCerts.Count -gt 0) {
        $goDaddyMissing = $missingCerts | Where-Object { $_.Subject -match 'Go Daddy|GoDaddy|Starfield' }
        if ($goDaddyMissing) {
            Write-Output "FLAG: Missing GoDaddy/Starfield root(s) - relevant to the active G2->R1 transition:"
            $goDaddyMissing | ForEach-Object { Write-Output "  - $($_.Subject)  [Thumbprint: $($_.Thumbprint)]" }
        }

        # Decision/action + summary printed FIRST, before the long per-cert detail dump below.
        # With 500+ missing certs on a fresh box, that detail dump can push this result past
        # where NinjaOne's activity pane truncates output - so this must not depend on scrolling
        # or expanding to be seen.
        if ($reportOnly) {
            Write-Output "==================================================================="
            Write-Output "RESULT: Report-only mode. NO CHANGES MADE."
            Write-Output "Re-run with reportOnly unchecked to import the $($missingCerts.Count) missing root(s) listed below."
            Write-Output "==================================================================="
        } else {
            Write-Output "==================================================================="
            Write-Output "RESULT: Importing $($missingCerts.Count) missing root(s) into Cert:\LocalMachine\Root..."
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
            $store.Open('ReadWrite')
            foreach ($cert in $missingCerts) {
                $store.Add($cert)
            }
            $store.Close()
            Write-Output "RESULT: Import complete. $($missingCerts.Count) root(s) added."
            Write-Output "==================================================================="
        }

        Write-Output "--- Missing root detail (informational, listed below) ---"
        foreach ($cert in $missingCerts) {
            Write-Output "  Subject:    $($cert.Subject)"
            Write-Output "  Thumbprint: $($cert.Thumbprint)"
            Write-Output "  NotAfter:   $($cert.NotAfter)"
            Write-Output ""
        }
    } else {
        Write-Output "RESULT: Local Root store is in sync with the WU catalog. No action needed."
    }
}
finally {
    if (Test-Path $sstPath) {
        Remove-Item $sstPath -Force -ErrorAction SilentlyContinue
    }
}
