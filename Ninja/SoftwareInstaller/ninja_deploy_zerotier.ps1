<#
.SYNOPSIS
    Installs the ZeroTier client (if needed) and joins a specified ZeroTier network.

.DESCRIPTION
    Designed for NinjaOne deployment in SYSTEM context. Performs three idempotent stages:
      1. Installs ZeroTier via the official MSI if the client isn't already present.
         "Installed" is determined by whether the ZeroTierOneService Windows service exists,
         not by file presence — ProgramData is persistent app-state and can survive an uninstall.
      2. Joins the target network using the "drop file" method (writes an empty
         <NetworkId>.conf into networks.d and restarts the service) rather than
         calling the CLI directly to join.
      3. Verifies the network appears in the CLI's listnetworks output and exits
         with a status code NinjaOne can key a condition/alert off of.

    Note: joining a network here does NOT authorize the endpoint. Authorization
    still has to happen manually (or via API) in ZeroTier Central before traffic
    routes — this script only gets the client to the "requesting join" state.

    ====================================================================================
    REQUIRED SETUP BEFORE FIRST RUN — add these as NinjaOne Script Variables on this
    Automation Library entry (Script Variables panel, not the PowerShell param block):
        networkId  (Text, REQUIRED)  — the 16-character ZeroTier network ID to join.
                                        Set the value per client/policy when assigning the task.
        msiUrl     (Text, optional)  — override MSI download URL. Leave blank to always
                                        install ZeroTier's current stable release.
    Without networkId set, the script exits immediately with a validation error.
    ====================================================================================

.NOTES
    Author:         Chad
    Last Edit:      08-31-2026
    GitHub:         MSP-Scripts/Ninja/SoftwareInstaller/ninja_deploy_zerotier.ps1
    Environment:    Windows 10/11, NinjaOne RMM (SYSTEM context)
    Requires:       Administrator/SYSTEM privileges; ZeroTier MSI reachable locally or via URL
    Version:        1.0
    Ninja Note:     Script Variables required —
                       - networkId   (Text, required)  -> maps to $env:networkId, the 16-char ZeroTier network ID.
                                                            Set this per-client/per-policy in the NinjaOne script
                                                            variable field when assigning the Automation task.
                       - msiUrl      (Text, optional)   -> maps to $env:msiUrl, direct download URL for the ZeroTier MSI.
                                                            Leave blank to always pull ZeroTier's current stable release
                                                            from download.zerotier.com (default below).
                     No checkbox variables used in this version.

.CHANGELOG
    1.0 - 08-31-2026 - Initial public release. Installs ZeroTier via MSI when the ZeroTierOneService service
                        isn't present (file presence alone is not trusted, since ProgramData persists across
                        an uninstall), auto-joins the target network via the drop-file method, and verifies
                        the join through the CLI. Service restarts use explicit Stop-Service/Start-Service with
                        WaitForStatus and retry/backoff, since the MSI's own install action starts the service
                        asynchronously and a bare Restart-Service can hit it mid-transition. CLI path resolution
                        checks known ZeroTier 1.16.x locations (zerotier-cli.bat and its underlying
                        zerotier-one_x64.exe) with older .exe naming kept as fallback for prior versions.

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$NetworkId = $env:networkId,

    [Parameter()]
    [string]$MsiUrl = $(if ($env:msiUrl) { $env:msiUrl } else { "https://download.zerotier.com/dist/ZeroTier%20One.msi" }),

    [Parameter()]
    [string]$MsiPath = "C:\ProgramData\ZeroTier\ZeroTierOne.msi"
)

$ErrorActionPreference = "Stop"
$NetworksDir  = "C:\ProgramData\ZeroTier\One\networks.d"
$ServiceName  = "ZeroTierOneService"

function Write-Log {
    param([string]$Message)
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Resolve-ZtExePath {
    # Confirmed via an actual install (folder listing + zerotier-cli.bat contents):
    # the CLI entry point is zerotier-cli.bat, a wrapper that calls the real executable at
    # C:\ProgramData\ZeroTier\One\zerotier-one_x64.exe with -q. The .bat handles -q internally, so we
    # call it plain. The ProgramData .exe is kept as a direct fallback in case the .bat is ever missing.
    $candidates = @(
        "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat",
        "C:\Program Files\ZeroTier\One\zerotier-cli.bat",
        "C:\ProgramData\ZeroTier\One\zerotier-one_x64.exe",
        "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.exe",
        "C:\Program Files\ZeroTier\ZeroTier One\zerotier-cli.exe",
        "C:\Program Files\ZeroTier\One\zerotier-cli.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Invoke-ZtCli {
    # zerotier-cli.bat and legacy zerotier-cli.exe both take commands directly (no -q prefix needed).
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    if ($ExePath -match 'zerotier-one_x(64|86)\.exe$') {
        & $ExePath -q @Arguments 2>$null
    }
    else {
        & $ExePath @Arguments 2>$null
    }
}

function Restart-ZtService {
    # Restart-Service alone fails outright if SCM has the service in a transitional (Pending) state -
    # which happens right after install, since the MSI's own custom action starts the service
    # asynchronously. Waits for a stable state before acting, and retries instead of failing on first hit.
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$MaxAttempts = 4,
        [int]$RetryDelaySeconds = 5
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $svc = Get-Service -Name $Name -ErrorAction Stop

            if ($svc.Status -match 'Pending') {
                Write-Log "$Name is in a transitional state ($($svc.Status)) — waiting before attempt $attempt."
                $targetStatus = if ($svc.Status -match 'Stop') { 'Stopped' } else { 'Running' }
                $svc.WaitForStatus($targetStatus, (New-TimeSpan -Seconds 20))
                $svc.Refresh()
            }

            if ($svc.Status -eq 'Running') {
                Stop-Service -Name $Name -Force -ErrorAction Stop
                $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 20))
            }

            Start-Service -Name $Name -ErrorAction Stop
            $svc.WaitForStatus('Running', (New-TimeSpan -Seconds 20))
            return $true
        }
        catch {
            Write-Log "Restart attempt $attempt/$MaxAttempts for $Name failed: $($_.Exception.Message)"
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }
    return $false
}

# --- Validate network ID -------------------------------------------------
if ([string]::IsNullOrWhiteSpace($NetworkId) -or $NetworkId -notmatch '^[0-9a-fA-F]{16}$') {
    Write-Log "ERROR: NetworkId '$NetworkId' is missing or not a valid 16-character hex ZeroTier network ID."
    exit 1
}
$NetworkId = $NetworkId.ToLower()

# --- Stage 1: Install if missing -----------------------------------------
# "Installed" is decided by the SERVICE existing, not by any file being present. ProgramData is
# persistent app-state and survives an MSI uninstall (identity, config, and even the .exe can be left
# behind) - trusting a stale file there previously caused a false "already installed" after a real
# uninstall. The service is what everything downstream (restart, join) actually depends on.
$ServiceExists = [bool](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
$ZtExePath = Resolve-ZtExePath

if (-not $ServiceExists) {
    if ($ZtExePath) {
        Write-Log "$ServiceName not found, but found leftover files at $ZtExePath (likely from a prior uninstall that didn't clean ProgramData). Proceeding with install regardless."
    }
    else {
        Write-Log "ZeroTier not found. Installing..."
    }

    if ($MsiUrl) {
        Write-Log "Downloading MSI from $MsiUrl"
        $MsiDir = Split-Path -Path $MsiPath -Parent
        if (-not (Test-Path $MsiDir)) {
            New-Item -ItemType Directory -Force -Path $MsiDir | Out-Null
        }
        Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing

        $downloadedSize = (Get-Item $MsiPath).Length
        Write-Log "Downloaded MSI size: $downloadedSize bytes."
        if ($downloadedSize -lt 1MB) {
            Write-Log "ERROR: Downloaded file is suspiciously small ($downloadedSize bytes) — likely a truncated download, a redirect/error page, or an AV quarantine placeholder. Aborting before install."
            exit 1
        }
    }

    if (-not (Test-Path $MsiPath)) {
        Write-Log "ERROR: No MSI found at '$MsiPath' and no msiUrl provided. Cannot install."
        exit 1
    }

    $msiLogPath = "C:\ProgramData\ZeroTier\zerotier_install.log"
    $msiArgs = "/i `"$MsiPath`" /qn /norestart /l*v `"$msiLogPath`""
    $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    Write-Log "msiexec exited with code $($proc.ExitCode)."
    if ($proc.ExitCode -ne 0) {
        Write-Log "ERROR: msiexec exited with code $($proc.ExitCode)."
        exit 1
    }

    # Give the service a moment to register/start after install
    $installTimeout = 60
    $waited = 0
    while ((-not $ZtExePath -or -not $ServiceExists) -and $waited -lt $installTimeout) {
        Start-Sleep -Seconds 2
        $waited += 2
        $ZtExePath = Resolve-ZtExePath
        $ServiceExists = [bool](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
    }

    if (-not $ZtExePath -or -not $ServiceExists) {
        Write-Log "ERROR: Install verification failed after ${installTimeout}s (executable found: $([bool]$ZtExePath), service found: $ServiceExists)."
        if (Test-Path $msiLogPath) {
            Write-Log "Tail of MSI log ($msiLogPath):"
            Get-Content -Path $msiLogPath -Tail 40 | ForEach-Object { Write-Log $_ }
        }
        else {
            Write-Log "No MSI log found at $msiLogPath either — msiexec may not have run at all."
        }
        exit 1
    }
    Write-Log "Install confirmed."
}
else {
    Write-Log "ZeroTier already installed ($ServiceName service present)."
    if (-not $ZtExePath) {
        Write-Log "ERROR: Service exists but no CLI executable found in any known location — installation may be corrupted. Manual investigation needed."
        exit 1
    }
}

# --- Stage 2: Join network (drop-file method, idempotent) ----------------
$confFile = Join-Path $NetworksDir "$NetworkId.conf"

if (Test-Path $confFile) {
    Write-Log "Network $NetworkId already present in networks.d — skipping join, will still verify below."
}
else {
    Write-Log "Joining network $NetworkId via drop-file method."
    New-Item -ItemType Directory -Force -Path $NetworksDir | Out-Null
    New-Item -ItemType File -Force -Path $confFile | Out-Null

    Write-Log "Restarting $ServiceName to pick up new network config."
    if (-not (Restart-ZtService -Name $ServiceName)) {
        Write-Log "ERROR: Could not restart $ServiceName after multiple attempts. Service may still be in a transitional state — check manually with Get-Service $ServiceName."
        exit 1
    }
    Write-Log "$ServiceName restarted successfully."
}

# --- Stage 3: Verify -------------------------------------------------------
$verifyTimeout = 30
$waited = 0
$joined = $false

Write-Log "Verifying join via ZeroTier CLI listnetworks (timeout ${verifyTimeout}s)..."
while ($waited -lt $verifyTimeout) {
    try {
        $networks = Invoke-ZtCli -ExePath $ZtExePath -Arguments @("listnetworks")
        if ($networks -match $NetworkId) {
            $joined = $true
            break
        }
    }
    catch {
        # service may still be restarting; ignore and retry
    }
    Start-Sleep -Seconds 3
    $waited += 3
}

if ($joined) {
    Write-Log "SUCCESS: Network $NetworkId is present on this client. Remember it still needs authorization in ZeroTier Central."
    exit 0
}
else {
    Write-Log "ERROR: Network $NetworkId did not appear in listnetworks output within ${verifyTimeout}s."
    exit 1
}
