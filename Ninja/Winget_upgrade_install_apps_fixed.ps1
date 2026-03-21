#Requires -Version 5.1

<#
===============================================================================
SCRIPT:      Winget_upgrade_install_apps_fixed.ps1
AUTHOR:      Chad Mark
PLATFORM:    NinjaRMM
REPOSITORY:  https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/Winget_upgrade_install_apps_fixed.ps1
CREATED:     03/20/2026
UPDATED:     03/21/2026

DESCRIPTION:
    Installs, upgrades, or uninstalls a software package on a Windows machine
    using WinGet (Windows Package Manager). If WinGet is not installed, the
    script can optionally install it along with its dependencies. Must be run
    as a local admin user - WinGet does NOT work under the SYSTEM account.

USAGE (NinjaRMM Script Variables):
    action                   - Required. Install | Upgrade | Uninstall
    packageId                - Required. WinGet package ID (e.g. "Google.Chrome")
                               Find IDs at: https://winget.run or run: winget search <name>
    scope                    - Optional. user | machine - sets install scope
    locale                   - Optional. Locale for install (e.g. "en-US")
    acceptPackageAgreements  - Checkbox. Auto-accept package license agreements
    acceptSourceAgreements   - Checkbox. Auto-accept WinGet source agreements (required for Uninstall)
    silent                   - Checkbox. Run installer silently with no UI
    installWingetIfNecessary - Checkbox. Install WinGet if it is not already present

NOTES:
    - Must run as LOCAL ADMIN - NOT as SYSTEM
    - In NinjaRMM use "Run As" with a local admin credential
      https://ninjarmm.zendesk.com/hc/en-us/articles/360016094532-Credential-Exchange
    - Minimum OS: Windows 10, Windows Server 2016
    - acceptSourceAgreements is required for Uninstall actions
    - VCLibs dependency hash check is skipped during WinGet install - Microsoft
      does not publish a hash for this file and it updates without notice

CHANGE LOG:
    03/20/2026 - Initial version. Fixed VCLibs hardcoded hash issue; hash check
                 now skipped for VCLibs only since Microsoft provides no hash source
    03/21/2026 - Added standard header block with repository link
===============================================================================
#>

param(
    [Parameter()]
    [string[]]$WinGetArgs
)

begin {
    $WinGetPath = "C:\Users\$env:USERNAME\AppData\Local\Microsoft\WindowsApps\winget.exe"
    Write-Host "Path to WinGet: $WinGetPath"

    #Region Helper Functions
    function Update-EnvironmentVariables {
        foreach ($level in "Machine", "User") {
            [Environment]::GetEnvironmentVariables($level).GetEnumerator() | ForEach-Object {
                # For Path variables, append the new values, if they're not already in there
                if ($_.Name -match 'Path$') {
                    $_.Value = ($((Get-Content "Env:$($_.Name)") + ";$($_.Value)") -split ';' | Select-Object -Unique) -join ';'
                }
                $_
            } | Set-Content -Path { "Env:$($_.Name)" }
        }
    }

    function Get-LatestUrl($Url, $FileName) {
        $((Invoke-WebRequest $Url -UseBasicParsing | ConvertFrom-Json).assets | Where-Object { $_.name -match "^$FileName`$" }).browser_download_Url
    }

    function Get-LatestHash($Url, $FileName) {
        $shaUrl = $((Invoke-WebRequest $Url -UseBasicParsing | ConvertFrom-Json).assets | Where-Object { $_.name -match "^$FileName`$" }).browser_download_Url
        [System.Text.Encoding]::UTF8.GetString($(Invoke-WebRequest -Uri $shaUrl -UseBasicParsing).Content)
    }
    function Test-IsElevated {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    function Test-IsSystem {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return $id.Name -like "NT AUTHORITY*" -or $id.IsSystem
    }
    #EndRegion Helper Functions

    if (-not (Test-IsElevated)) {
        Write-Warning "Many apps require administrator privileges in order to install, uninstall, or upgrade. This action may fail however some apps like Zoom may work."
    }

    if ((Test-IsSystem)) {
        Write-Error -Message "WinGet will not run under a System account. Use a user account with Administrator privileges. https://ninjarmm.zendesk.com/hc/en-us/articles/360016094532-Credential-Exchange"
        exit 1
    }
}
process {
    try {
        $Version = & $WinGetPath "--version"
        Write-Host "WinGet $Version found."
    }
    catch {
        Write-Host "WinGet not installed."
        if ($env:installWingetIfNecessary -like "True") {
            Write-Host "Installing WinGet."

            $apiLatestUrl = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol::Tls13 -bor [System.Net.SecurityProtocolType]::Tls12

            # Hide the progress bar of Invoke-WebRequest
            $oldProgressPreference = $ProgressPreference
            $ProgressPreference = 'Silent'
            $desktopAppInstaller = @{
                FileName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
                Url      = $(Get-LatestUrl -Url $apiLatestUrl -FileName "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle")
                Hash     = $(Get-LatestHash -Url $apiLatestUrl -FileName "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt")
            }
            $vcLibsUwp = @{
                FileName = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
                Url      = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
                # No hardcoded hash - Microsoft does not provide a public hash file for this URL.
                # Hash check is skipped for this dependency only (see download loop below).
                Hash     = $null
            }
            $uiLibsUwp = @{
                FileName = 'Microsoft.UI.Xaml.2.7.zip'
                Url      = 'https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.7.0'
                Hash     = "422FD24B231E87A842C4DAEABC6A335112E0D35B86FAC91F5CE7CF327E36A591"
            }

            # Combine dependencies into an array
            $Dependencies = @($desktopAppInstaller, $vcLibsUwp, $uiLibsUwp)

            $script:HashMismatch = $false
            # Download dependencies
            foreach ($Dependency in $Dependencies) {
                $Dependency.file = $Dependency.FileName
                Invoke-WebRequest $Dependency.Url -OutFile $Dependency.file
                # Skip hash check if no hash is defined (e.g. VCLibs - Microsoft does not publish a hash for this URL)
                if ($null -eq $Dependency.Hash) {
                    Write-Host "$($Dependency.FileName) - No hash defined, skipping hash check."
                    continue
                }
                $Hash = $(Get-FileHash -Path $Dependency.file).Hash
                if ($Hash -notlike $Dependency.Hash) {
                    Write-Host "$($Dependency.FileName) Hash does not match!"
                    Write-Host "Expected Hash: $($Dependency.Hash)"
                    Write-Host "Downloaded File Hash: $Hash"
                    $HashMismatch = $true
                }
            }

            if ($HashMismatch) {
                Write-Error -Message "Hash Mismatch" -RecommendedAction ""
                # Clean up downloaded files
                Remove-Item -Path $Dependencies.FileName
                exit 1
            }

            # Extract Microsoft.UI.Xaml
            $uiLibsUwpWithOutExtension = $(($uiLibsUwp.FileName -split '\.' | Select-Object -SkipLast 1) -join '.')
            Expand-Archive -Path $uiLibsUwp.file -DestinationPath "$env:TEMP\$uiLibsUwpWithOutExtension" -Force
            $uiLibsUwp.file = "$env:TEMP\$uiLibsUwpWithOutExtension\tools\AppX\x64\Release\$uiLibsUwpWithOutExtension.appx"

            # Install WinGet
            Add-AppxPackage -Path $desktopAppInstaller.file -DependencyPath $vcLibsUwp.file, $uiLibsUwp.File

            # Cleanup downloaded files
            Remove-Item -Path $desktopAppInstaller.file
            Remove-Item -Path $vcLibsUwp.file
            Remove-Item -Recurse -Path "$env:TEMP\$uiLibsUwpWithOutExtension*"

            Write-Host "WinGet installed!"

            Invoke-WebRequest -Uri "https://cdn.winget.microsoft.com/cache/source.msix" -OutFile "$env:TEMP\Microsoft.Winget.Source.msix" -UseBasicParsing
            Add-AppxPackage -Path "$env:TEMP\Microsoft.Winget.Source.msix"
            Remove-Item -Path "$env:TEMP\Microsoft.Winget.Source.msix"

            $ProgressPreference = $oldProgressPreference

            Update-EnvironmentVariables

            $ProgressPreference = 'Continue'
        }
        else {
            Write-Host "WinGet is required to be installed."
            exit 1
        }
    }
    
    if (-not $PSBoundParameters.ContainsKey("WinGetArgs")) {

        if ($env:useNameFlag -like "true" -and $env:packageNameOrQuery -like "null") {
            Write-Error "Missing package name!"
            exit 1
        }

        if ($env:action -like "Install") {
            $WinGetArgs += "install"
        }
        elseif ($env:action -like "Uninstall") {
            $WinGetArgs += "uninstall"
        }
        elseif ($env:action -like "Upgrade") {
            $WinGetArgs += "upgrade"
        }
        elseif ($env:action -and $env:action -notlike "null") {
            Write-Error "You must specify an action to take (Install, Uninstall or Upgrade)."
            exit 1
        }

        if ($env:packageId -and $env:packageId -notlike "null") {
            $WinGetArgs += "--id", $env:packageId
        }

        if ($env:scope -and $env:scope -notlike "null") {
            $WinGetArgs += "--scope", $env:scope
        }

        if ($env:locale -and $env:locale -notlike "null") {
            $WinGetArgs += "--locale", $env:locale
        }

        if ($env:acceptPackageAgreements -like "True" -and $env:action -notlike "uninstall") {
            $WinGetArgs += "--accept-package-agreements"
        }

        if ($env:acceptSourceAgreements -like "True") {
            $WinGetArgs += "--accept-source-agreements"
        }

        if ($env:silent -like "True") {
            $WinGetArgs += "--silent"
        }

        $WinGetArgs += "--source", "winget"

    }

    # Validate arguments to avoid hanging on user input when uninstalling a package
    if ($env:action -like "Uninstall" -and $env:acceptSourceAgreements -notlike "True") {
        Write-Host "Accept Source Agreements is required to continue."
        exit 1
    }

    # Validate arguments to avoid hanging on user input when installing or upgrading a package
    if (
        $(
            $env:action -like "Install" -or
            $env:action -like "Upgrade"
        ) -and $env:acceptPackageAgreements -like "false" -and $env:acceptSourceAgreements -like "false"
    ) {
        Write-Host "Accept Package and Source Agreements is required to continue."
        exit 1
    }

    # Run WinGet
    $winget = Start-Process $WinGetPath -ArgumentList $WinGetArgs -Wait -PassThru -NoNewWindow

    if ($winget.ExitCode -eq -1978335217) {

        # Sources need to be reset and updated
        Write-Host "Attempting to reset source."
        $resetSource = Start-Process $WinGetPath -ArgumentList "source", "reset", "--force" -Wait -PassThru -NoNewWindow
        Start-Sleep 1

        Write-Host "Attempting to update sources."
        $updateSource = Start-Process $WinGetPath -ArgumentList "source", "update" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\ninjaone-rmm-updatesource-output.txt"
        Start-Sleep 1

        if ($updateSource.ExitCode -lt 0 -or ((Get-Content "$env:TEMP\ninjaone-rmm-updatesource-output.txt") -contains "Cancelled")) {
            # Update sources once more if exit code is not 0
            Write-Host "Attempting to update sources by adding the Microsoft.WinGet.Source package."

            try {
                Invoke-WebRequest -Uri "https://cdn.winget.microsoft.com/cache/source.msix" -OutFile "$env:TEMP\Microsoft.Winget.Source.msix" -UseBasicParsing -ErrorAction Stop
                Add-AppxPackage -Path "$env:TEMP\Microsoft.Winget.Source.msix" -ErrorAction Stop
            }
            catch {
                Write-Host "Error updating sources. Try running ""winget source update"" in the console or use the Parameter -WinGetArgs with ""source update"" alone to fix this error."
                Write-Host "Exit Code: $($updateSource.ExitCode)"
                exit $updateSource.ExitCode
            }
            Write-Host "Successfully added winget source"
        }
        Write-Host "Running WinGet with original arguments once more."
        $winget = Start-Process $WinGetPath -ArgumentList $WinGetArgs -Wait -PassThru -NoNewWindow
        Start-Sleep 1
    }
    Write-Host "Exit Code: $($winget.ExitCode)"
    exit $winget.ExitCode

}
end {
    
    
    
}