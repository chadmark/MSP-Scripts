<#
.SYNOPSIS
    Upgrades Windows 11 24H2 or 25H2 to 26H2 using the KB5121794 enablement package (eKB).

.DESCRIPTION
    Windows 11 24H2, 25H2 and 26H2 share one servicing branch, so 26H2 is turned on by a
    ~174 KB enablement package with a single restart. This script:
      - Relaunches in 64-bit PowerShell if started from a 32-bit host
      - Skips machines already on 26H2 (build 26300+)
      - Blocks machines not on 24H2 (26100) or 25H2 (26200), which need a full feature update
      - Detects an already-installed eKB that is just waiting on a reboot
      - Verifies the KB5120998 prerequisite (UBR 9278+ on 26100 or 26200)
      - Detects x64 vs ARM64 (ARM checked first so ARM64 is not mistaken for x64)
      - Downloads via BITS with Invoke-WebRequest fallback and retries
      - Verifies file size, SHA-1 (from Microsoft's file name) and Microsoft Authenticode signature
      - Installs silently with wusa.exe and handles reboot per the Reboot setting
      - Writes a transcript log and wusa .evtx log to C:\ProgramData\Win11-26H2

.PARAMETER Reboot
    Reboot behavior after install: None (default), Force (60-second delayed restart), or Prompt
    (interactive sessions only; falls back to None under SYSTEM/RMM).
    Overridden by the NinjaOne variable rebootBehavior when present.

.PARAMETER RetryCount
    Number of download attempts (1-10, default 3).

.PARAMETER RetryDelaySec
    Seconds between download attempts (1-60, default 5).

.NOTES
    Author      : Chad Markley, Markley Technologies
    Based On    : Mikhail Deynekin, paulmann/Windows-11-25H2-Update-Script (KB5054156 version)
    Last Edit   : 10-31-2026
    GitHub      : MSP-Scripts/ninja/ninja_Upgrade_Win11_26H2_eKB.ps1
    Environment : NinjaOne (run as System) or elevated interactive PowerShell
    Requires    : PowerShell 5.1 or 7+, Administrator/SYSTEM,
                  Windows 11 24H2 (26100) or 25H2 (26200) at UBR 9278+ (KB5120998 or later CU)
    Version     : 1.0
    Ninja Note  : Script variable (optional):
                    Name            : Reboot Behavior
                    Calculated Name : rebootBehavior
                    Type            : Drop-down (None, Force, Prompt)
                  If the variable is blank or missing, the script uses None.
                  Run As: System. Exit 0 = upgraded / already 26H2 / pending reboot.
                  Exit 1 = failure or device not eligible (see log in C:\ProgramData\Win11-26H2).

.CHANGELOG
    1.0 - 10-31-2026 - Initial release for Windows 11 26H2 (KB5121794), adapted from paulmann 25H2 eKB script: pinned x64/ARM64 URLs with SHA-1 + signature checks, KB5120998 UBR prereq for 24H2/25H2, pending-reboot detection, ARM-first architecture detection, NinjaOne rebootBehavior variable, non-interactive reboot handling, 64-bit relaunch, wusa .evtx logging. Tested on 25H2 (26200.9711) via NinjaOne as SYSTEM

.LINK
    https://github.com/chadmark/MSP-Scripts
    https://support.microsoft.com/kb/5121794
#>

[CmdletBinding()]
param(
    [ValidateSet('Prompt', 'Force', 'None')]
    [string]$Reboot = 'None',
    [ValidateRange(1, 10)]
    [int]$RetryCount = 3,
    [ValidateRange(1, 60)]
    [int]$RetryDelaySec = 5
)

#region 64-bit relaunch
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysNativePs = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $sysNativePs) {
        & $sysNativePs -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
            -Reboot $Reboot -RetryCount $RetryCount -RetryDelaySec $RetryDelaySec
        exit $LASTEXITCODE
    }
}
#endregion

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

#region Constants
$Script:KB           = 'KB5121794'
$Script:PrereqKB     = 'KB5120998'
$Script:TargetBuild  = 26300            # 26H2
$Script:SourceBuilds = @(26100, 26200)  # 24H2, 25H2
$Script:MinimumUbr   = 9278             # KB5120998 baseline (26100.9278 / 26200.9278)
$Script:MinFileBytes = 100000
$Script:Package = @{
    'AMD64' = @{
        Url  = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/94520a88-858f-4832-a57d-7211f6d84a4e/public/Windows11.0-KB5121794-x64_5e20a3cce48d6611b16bdec42b07167f5456586a.msu'
        Sha1 = '5e20a3cce48d6611b16bdec42b07167f5456586a'
    }
    'ARM64' = @{
        Url  = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/9d8dc3d0-9cbf-4eb1-9411-722e3e6a19b3/public/Windows11.0-KB5121794-arm64_77a76caf2d362bb293a4d18058388f2717365abe.msu'
        Sha1 = '77a76caf2d362bb293a4d18058388f2717365abe'
    }
}
$Script:LogDir  = Join-Path $env:ProgramData 'Win11-26H2'
$Script:LogFile = Join-Path $Script:LogDir ("Upgrade_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$Script:TempMsu = $null
#endregion

#region Helpers
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')][string]$Level = 'Info'
    )
    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   { 'Cyan' }
    }
    Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message) -ForegroundColor $color
}

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-InteractiveSession {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Environment]::UserInteractive -and -not $identity.IsSystem)
}

function Get-OSArchitecture {
    # ARM must be checked first: ARM64 reports "ARM 64-bit Processor", which also matches "64"
    $osArch = $null
    try { $osArch = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).OSArchitecture } catch { }
    if ($osArch -match 'ARM') { return 'ARM64' }
    if ($osArch -match '64')  { return 'AMD64' }

    # Fallback: machine-level (native) processor architecture
    $native = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE
    if ($native -in @('AMD64', 'ARM64')) { return $native }
    return $null
}

function Get-OSBuildInfo {
    $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    # Registry ProductName still says "Windows 10" on Windows 11; CIM Caption is accurate
    $caption = $null
    try { $caption = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }
    if (-not $caption) { $caption = $reg.ProductName }
    [PSCustomObject]@{
        ProductName    = $caption
        DisplayVersion = $reg.DisplayVersion
        CurrentBuild   = [int]$reg.CurrentBuild
        UBR            = [int]$reg.UBR
    }
}

function Test-EkbInstalled {
    # True when the eKB is installed but the device has not restarted onto 26300 yet
    return [bool](Get-HotFix -Id $Script:KB -ErrorAction SilentlyContinue)
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        Write-Log "Download attempt $attempt of $RetryCount..."
        try {
            try {
                Start-BitsTransfer -Source $Uri -Destination $OutFile -ErrorAction Stop
            }
            catch {
                Write-Log "BITS failed ($($_.Exception.Message)); falling back to Invoke-WebRequest" -Level Warning
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            }
            Write-Log "Download completed" -Level Success
            return
        }
        catch {
            Write-Log "Attempt $attempt failed: $($_.Exception.Message)" -Level Warning
            if ($attempt -lt $RetryCount) { Start-Sleep -Seconds $RetryDelaySec }
        }
    }
    throw "Download failed after $RetryCount attempts"
}

function Test-PackageIntegrity {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$ExpectedSha1
    )
    $size = (Get-Item $FilePath).Length
    if ($size -lt $Script:MinFileBytes) {
        throw "Downloaded file is only $size bytes (expected ~175 KB); likely an error page, not the MSU"
    }

    $sha1 = (Get-FileHash -Path $FilePath -Algorithm SHA1).Hash.ToLower()
    if ($sha1 -ne $ExpectedSha1.ToLower()) {
        throw "SHA-1 mismatch. Expected $ExpectedSha1, got $sha1"
    }
    Write-Log "SHA-1 verified: $sha1" -Level Success

    $sig = Get-AuthenticodeSignature -FilePath $FilePath
    if ($sig.Status -ne 'Valid') { throw "Invalid signature status: $($sig.Status)" }
    if ($sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
        throw "Untrusted signer: $($sig.SignerCertificate.Subject)"
    }
    Write-Log "Authenticode signature verified (Microsoft Corporation)" -Level Success
}

function Invoke-RebootHandler {
    param([string]$RebootBehavior)
    switch ($RebootBehavior) {
        'Force' {
            Write-Log "Scheduling restart in 60 seconds to finish the 26H2 upgrade" -Level Warning
            & shutdown.exe /r /t 60 /c "Markley Technologies: restarting to complete the Windows 11 26H2 upgrade." | Out-Null
        }
        'Prompt' {
            if (Test-InteractiveSession) {
                $answer = Read-Host "A restart is required to finish the 26H2 upgrade. Restart now? (Y/N)"
                if ($answer -match '^[Yy]') {
                    Write-Log "Restarting now" -Level Warning
                    Restart-Computer -Force
                }
                else {
                    Write-Log "Restart deferred. 26H2 activates on the next restart." -Level Warning
                }
            }
            else {
                Write-Log "Prompt requested but session is non-interactive (SYSTEM/RMM); treating as None" -Level Warning
                Write-Log "Restart pending. 26H2 activates on the next restart." -Level Warning
            }
        }
        default {
            Write-Log "Restart suppressed. 26H2 activates on the next restart." -Level Warning
        }
    }
}
#endregion

#region Main
try {
    New-Item -Path $Script:LogDir -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $Script:LogFile -Force | Out-Null
    Write-Log "Windows 11 26H2 eKB ($Script:KB) upgrade started"

    # NinjaOne variable override
    if (-not [string]::IsNullOrWhiteSpace($env:rebootBehavior)) {
        $ninjaReboot = $env:rebootBehavior.Trim()
        if ($ninjaReboot -in @('None', 'Force', 'Prompt')) {
            $Reboot = $ninjaReboot
            Write-Log "Reboot behavior from NinjaOne variable: $Reboot"
        }
        else {
            Write-Log "Ignoring invalid rebootBehavior value '$ninjaReboot'; using $Reboot" -Level Warning
        }
    }

    if (-not (Test-Administrator)) {
        throw "Administrator or SYSTEM privileges are required"
    }

    $os = Get-OSBuildInfo
    Write-Log "Current OS: $($os.ProductName) $($os.DisplayVersion), build $($os.CurrentBuild).$($os.UBR)"

    # 1. Already on 26H2 (or a newer branch)
    if ($os.CurrentBuild -ge $Script:TargetBuild) {
        Write-Log "Device is already on build $($os.CurrentBuild) ($($os.DisplayVersion)). No action needed." -Level Success
        exit 0
    }

    # 2. Not on a 24H2/25H2 servicing branch
    if ($os.CurrentBuild -notin $Script:SourceBuilds) {
        Write-Log "Build $($os.CurrentBuild) is not 24H2 (26100) or 25H2 (26200). The eKB cannot be used; a full feature update or in-place upgrade is required." -Level Error
        exit 1
    }

    # 3. eKB already installed, waiting on restart
    if (Test-EkbInstalled) {
        Write-Log "$Script:KB is already installed and waiting on a restart" -Level Success
        Invoke-RebootHandler -RebootBehavior $Reboot
        exit 0
    }

    # 4. Prerequisite cumulative update
    if ($os.UBR -lt $Script:MinimumUbr) {
        Write-Log "UBR $($os.UBR) is below $Script:MinimumUbr. Install $Script:PrereqKB or a newer cumulative update first, then rerun." -Level Error
        exit 1
    }

    # 5. Architecture
    $arch = Get-OSArchitecture
    if (-not $arch -or -not $Script:Package.ContainsKey($arch)) {
        Write-Log "Could not determine a supported architecture (detected: '$arch')" -Level Error
        exit 1
    }
    Write-Log "Architecture: $arch"
    $pkg = $Script:Package[$arch]

    # 6. Download and verify
    $Script:TempMsu = Join-Path $env:TEMP "$($Script:KB)_$arch.msu"
    if (Test-Path $Script:TempMsu) { Remove-Item $Script:TempMsu -Force }
    Write-Log "Source: $($pkg.Url)"
    Invoke-FileDownload -Uri $pkg.Url -OutFile $Script:TempMsu
    Test-PackageIntegrity -FilePath $Script:TempMsu -ExpectedSha1 $pkg.Sha1

    # 7. Install
    $wusaLog = Join-Path $Script:LogDir ("wusa_{0:yyyyMMdd_HHmmss}.evtx" -f (Get-Date))
    Write-Log "Installing $Script:KB with wusa.exe (wusa log: $wusaLog)..."
    $proc = Start-Process -FilePath 'wusa.exe' -ArgumentList "`"$($Script:TempMsu)`" /quiet /norestart /log:`"$wusaLog`"" -Wait -PassThru
    $code = $proc.ExitCode
    $hex  = '0x{0:X8}' -f $code
    Write-Log "wusa.exe exit code: $code ($hex)"

    switch ($code) {
        { $_ -in @(0, 3010) } {
            Write-Log "$Script:KB installed. 26H2 activates after restart." -Level Success
            Invoke-RebootHandler -RebootBehavior $Reboot
            exit 0
        }
        2359302 {
            # 0x00240006 WU_S_ALREADY_INSTALLED
            Write-Log "$Script:KB is already installed; restart pending" -Level Success
            Invoke-RebootHandler -RebootBehavior $Reboot
            exit 0
        }
        -2145124329 {
            # 0x80240017 WU_E_NOT_APPLICABLE
            Write-Log "Update not applicable to this device. Confirm edition, build, and that $Script:PrereqKB or newer is installed." -Level Error
            exit 1
        }
        -2145124330 {
            # 0x80240016 WU_E_INSTALL_NOT_ALLOWED
            Write-Log "Another update installation is in progress. Rerun after it finishes." -Level Error
            exit 1
        }
        default {
            Write-Log "Installation failed with exit code $code ($hex). See $Script:LogFile" -Level Error
            exit 1
        }
    }
}
catch {
    Write-Log "Script failed: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    if ($Script:TempMsu -and (Test-Path $Script:TempMsu)) {
        Remove-Item $Script:TempMsu -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Log file: $Script:LogFile"
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
#endregion
