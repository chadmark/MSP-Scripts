#Requires -Version 5.1

<#
  .SYNOPSIS
    Installs Dell updates via Dell Command Update
  .DESCRIPTION
    Installs the latest version of Dell Command Update and applies all Dell updates silently.
    DCU version discovery uses Dell's SKU catalog (CatalogIndexPC.cab) instead of web scraping,
    ensuring the true latest version is always found without hardcoded fallback URLs or hashes.
  .NOTES
    Original Author: Aaron J. Stevenson
    Original Link:   https://github.com/wise-io/scripts/blob/main/scripts/DellCommandUpdate.ps1
    Author:          Chad
    Last Edit:       05-06-2026
    GitHub:          https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/Dell_CommandUpdate_Wise-io_UpdateScript.ps1
    Environment:     Windows 10/11
    Requires:        PowerShell 5.1+, Dell hardware
    Version:         1.6
  .LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding()]
param (
  [Switch]$Reboot
)

function Get-Architecture {
  # On PS x86, PROCESSOR_ARCHITECTURE reports x86 even on x64 systems.
  # To get the correct architecture, we need to use PROCESSOR_ARCHITEW6432.
  # PS x64 doesn't define this, so we fall back to PROCESSOR_ARCHITECTURE.
  # Possible values: amd64, x64, x86, arm64, arm
  if ($null -ne $ENV:PROCESSOR_ARCHITEW6432) { $Architecture = $ENV:PROCESSOR_ARCHITEW6432 }
  else {     
    if ((Get-CimInstance -ClassName CIM_OperatingSystem -ErrorAction Ignore).OSArchitecture -like 'ARM*') {
      if ( [Environment]::Is64BitOperatingSystem ) { $Architecture = 'arm64' }  
      else { $Architecture = 'arm' }
    }

    if ($null -eq $Architecture) { $Architecture = $ENV:PROCESSOR_ARCHITECTURE }
  }

  switch ($Architecture.ToLowerInvariant()) {
    { ($_ -eq 'amd64') -or ($_ -eq 'x64') } { return 'x64' }
    # { $_ -eq 'x86' } { return 'x86' } - DCU 5.X doesn't support 32-bit
    # { $_ -eq 'arm' } { return 'arm' } - DCU 5.X doesn't support 32-bit ARM
    { $_ -eq 'arm64' } { return 'arm64' }
    default { throw "Architecture '$Architecture' not supported." }
  }
}

function Get-InstalledApps {
  param(
    [Parameter(Mandatory)][String[]]$DisplayNames,
    [String[]]$Exclude
  )
  
  $RegPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )
  
  # Get applications matching criteria
  $BroadMatch = @()
  foreach ($DisplayName in $DisplayNames) {
    $AppsWithBundledVersion = Get-ChildItem -Path $RegPaths | Get-ItemProperty | Where-Object { $_.DisplayName -like "*$DisplayName*" -and $null -ne $_.BundleVersion }
    if ($AppsWithBundledVersion) { $BroadMatch += $AppsWithBundledVersion }
    else { $BroadMatch += Get-ChildItem -Path $RegPaths | Get-ItemProperty | Where-Object { $_.DisplayName -like "*$DisplayName*" } }
  }
  
  # Remove excluded apps
  $MatchedApps = @()
  foreach ($App in $BroadMatch) {
    if ($Exclude -notcontains $App.DisplayName) { $MatchedApps += $App }
  }

  return $MatchedApps | Sort-Object { [version]$_.BundleVersion } -Descending
}

function Remove-DellUpdateApps {
  param([String[]]$DisplayNames)

  # Check for specified products
  $Apps = Get-InstalledApps -DisplayNames $DisplayNames -Exclude 'Dell SupportAssist OS Recovery Plugin for Dell Update'
  foreach ($App in $Apps) {
    Write-Output "Attempting to remove $($App.DisplayName)..."
    try {
      if ($App.UninstallString -match 'msiexec') {
        $Guid = [regex]::Match($App.UninstallString, '\{[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}').Value
        Start-Process -NoNewWindow -Wait -FilePath 'msiexec.exe' -ArgumentList "/x $Guid /quiet /qn"
      }
      else { Start-Process -NoNewWindow -Wait -FilePath $App.UninstallString -ArgumentList '/quiet' }
      Write-Output "Successfully removed $($App.DisplayName) [$($App.DisplayVersion)]"
    }
    catch { 
      Write-Warning "Failed to remove $($App.DisplayName) [$($App.DisplayVersion)]"
      Write-Warning $_
      exit 1
    }
  }
}

function Install-DellCommandUpdate {
  function Get-DellXML {
    # Downloads a Dell CAB file from the given URI, extracts it, and returns the XML content.
    # Suppresses expand.exe console output. Cleans up temp files on completion.
    param([Parameter(Mandatory)][String]$Uri)

    $TempCAB = Join-Path $env:TEMP 'dell_temp.cab'
    $TempXML = Join-Path $env:TEMP 'dell_temp.xml'
    Remove-Item $TempCAB, $TempXML -Force -ErrorAction Ignore

    Invoke-WebRequest -Uri $Uri -OutFile $TempCAB -UseBasicParsing
    if (-not (Test-Path $TempCAB)) { throw "Unable to download CAB from $Uri" }

    Start-Process -Wait -NoNewWindow -FilePath 'expand.exe' -ArgumentList "`"$TempCAB`" `"$TempXML`"" -RedirectStandardOutput 'NUL'
    [xml]$Content = Get-Content $TempXML

    Remove-Item $TempCAB, $TempXML -Force -ErrorAction Ignore
    return $Content
  }

  function Test-DCUCompatibility {
    # Checks whether this machine's SKU catalog includes a DCU Windows Universal entry.
    # Returns $true if compatible, exits 0 with a friendly message if not.
    param([Parameter(Mandatory)][xml]$IndexXml)

    $SystemSKU     = (Get-CimInstance -ClassName Win32_ComputerSystem).SystemSKUNumber
    $MatchedModel  = $IndexXml.ManifestIndex.GroupManifest | Where-Object {
      $SystemSKU -match $_.SupportedSystems.Brand.Model.systemID
    } | Select-Object -First 1

    if ($null -eq $MatchedModel) {
      Write-Output "This Dell system (SKU: $SystemSKU) was not found in the Dell catalog - aborting..."
      exit 0
    }

    $ModelXml    = Get-DellXML -Uri "https://downloads.dell.com/$($MatchedModel.ManifestInformation.path)"
    $UniversalEntry = $ModelXml.Manifest.SoftwareComponent | Where-Object {
      $_.Name.Display.'#cdata-section' -match 'Command.+Windows Universal' -and
      $_.path -notlike '*WINARM*'
    } | Select-Object -First 1

    if ($null -eq $UniversalEntry) {
      Write-Output "This Dell system (SKU: $SystemSKU) does not support Dell Command Update Windows Universal - aborting..."
      exit 0
    }

    Write-Output "SKU $SystemSKU confirmed compatible with Dell Command Update Windows Universal."
  }

  function Get-LatestDCUFromCatalog {
    # Downloads Dell's master SKU catalog index and scans individual model catalogs
    # to find the highest available version of Dell Command Update Windows Universal.
    # No hardcoded URLs or version numbers - always resolves the true latest.
    param([Parameter(Mandatory)][xml]$IndexXml)

    $AllModels       = $IndexXml.ManifestIndex.GroupManifest
    $BestDCUEntry    = $null
    $BestDCUVersion  = [version]'0.0.0'
    $CatalogsChecked = 0

    Write-Output 'Scanning Dell catalogs for latest DCU version...'

    foreach ($Model in $AllModels) {
      # Once a DCU entry is found, check at least 10 more catalogs to confirm it's the highest, then stop
      if ($BestDCUEntry -and $CatalogsChecked -ge 10) { break }
      # Hard cap to keep runtime reasonable
      if ($CatalogsChecked -ge 75) { break }

      try {
        $ModelXml   = Get-DellXML -Uri "https://downloads.dell.com/$($Model.ManifestInformation.path)"
        $DCUEntries = $ModelXml.Manifest.SoftwareComponent | Where-Object {
          $_.Name.Display.'#cdata-section' -match 'Command.+Windows Universal' -and
          $_.path -notlike '*WINARM*'
        }

        foreach ($Entry in $DCUEntries) {
          try {
            $EntryVersion = [version]$Entry.VendorVersion
            if ($EntryVersion -gt $BestDCUVersion) {
              $BestDCUVersion = $EntryVersion
              $BestDCUEntry   = [PSCustomObject]@{
                Version  = $Entry.VendorVersion
                URL      = "https://$($ModelXml.Manifest.baseLocation)/$($Entry.path)"
                Checksum = ($Entry.Cryptography.Hash | Where-Object { $_.algorithm -eq 'SHA256' }).'#text'
              }
            }
          }
          catch { continue }
        }
      }
      catch { }
      finally { $CatalogsChecked++ }
    }

    if (-not $BestDCUEntry) {
      throw "Dell Command Update was not found in any of the $CatalogsChecked catalogs checked."
    }

    Write-Output "Found Dell Command Update version $($BestDCUEntry.Version) as the latest available."
    return $BestDCUEntry
  }

  # Download catalog index once - shared by both compatibility check and version scan
  Write-Output 'Downloading Dell catalog index...'
  $IndexXml  = Get-DellXML -Uri 'https://downloads.dell.com/catalog/CatalogIndexPC.cab'
  Test-DCUCompatibility -IndexXml $IndexXml
  $LatestDCU = Get-LatestDCUFromCatalog -IndexXml $IndexXml
  $Installer            = Join-Path -Path $env:TEMP -ChildPath (Split-Path $LatestDCU.URL -Leaf)
  $InstallerLog         = "$Installer.log"
  $CurrentVersion       = Get-InstalledApps -DisplayNames 'Dell Command | Update'
  $CurrentVersionString = ("$($CurrentVersion.DisplayName) [$($CurrentVersion.DisplayVersion)]").Trim()
  Write-Output "`nDell Command Update Version Info`n-----"
  Write-Output "Installed: $CurrentVersionString"
  Write-Output "Latest:    $($LatestDCU.Version)"

  if ($CurrentVersion.DisplayVersion -lt $LatestDCU.Version) {

    # Download installer
    Write-Output "`nDell Command Update installation needed"
    Write-Output 'Downloading...'
    Invoke-WebRequest -Uri $LatestDCU.URL -OutFile $Installer -UserAgent ([Microsoft.PowerShell.Commands.PSUserAgent]::Chrome)

    # Verify SHA256 checksum
    if ($null -ne $LatestDCU.Checksum) {
      Write-Output 'Verifying SHA256 checksum...'
      $InstallerChecksum = (Get-FileHash -Path $Installer -Algorithm SHA256).Hash
      if ($InstallerChecksum -ne $LatestDCU.Checksum.ToUpper()) {
        Write-Warning 'SHA256 checksum verification failed - aborting...'
        Remove-Item $Installer -Force -ErrorAction Ignore
        exit 1
      }
    }
    else { Write-Warning 'Unable to retrieve checksum from catalog for validation - skipping...' }

    # Remove existing version to avoid Classic / Universal incompatibilities 
    if ($CurrentVersion) { Remove-DellUpdateApps -DisplayNames 'Dell Command | Update' }

    # Install Dell Command Update
    Write-Output 'Installing latest...'
    $InstallerProcess = Start-Process -Wait -NoNewWindow -PassThru -FilePath $Installer -ArgumentList "/s /l=`"$InstallerLog`""
    Remove-Item $Installer -Force -ErrorAction Ignore

    # Confirm via exit code (0 = success, 2 = success + reboot required)
    if ($InstallerProcess.ExitCode -ne 0 -and $InstallerProcess.ExitCode -ne 2) {
      Write-Warning "DCU installer exited with code $($InstallerProcess.ExitCode). See log: $InstallerLog"
      exit 1
    }

    Write-Output "Successfully installed Dell Command Update [$($LatestDCU.Version)]`n"
  }
  else { Write-Output "`nDell Command Update installation / upgrade not needed`n" }
}

function Install-DotNetDesktopRuntime {
  function Get-LatestDotNetDesktopRuntime {
    try {
      $BaseURL = 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop'
      $Version = (Invoke-WebRequest -Uri "$BaseURL/8.0/latest.version" -UseBasicParsing).Content
      $URL = "$BaseURL/$Version/windowsdesktop-runtime-$Version-win-$Arch.exe"
      $ChecksumURL = "https://dotnet.microsoft.com/en-us/download/dotnet/thank-you/runtime-desktop-$Version-windows-$Arch-installer"

      # Retrieve SHA-512 checksum
      $DownloadPage = Invoke-WebRequest -UseBasicParsing -Uri $ChecksumURL -ErrorAction Ignore
      if ($DownloadPage -match 'id="checksum".*?([a-fA-F0-9]{128})') { $Checksum = $Matches[1] }

    }
    catch {}
    finally {
      # Confirm version number format
      if ($Version -notmatch '^\d+(\.\d+)+$') { 
        $URL = $null
        $Version = $null
      }
    }
  
    return @{
      Checksum = $Checksum.ToUpper()
      URL      = $URL
      Version  = $Version
    }
  }
  
  $LatestDotNet = Get-LatestDotNetDesktopRuntime
  $CurrentVersion = (Get-InstalledApps -DisplayName "Microsoft Windows Desktop Runtime*($Arch)").BundleVersion | Where-Object { $_ -like '8.*' }
  Write-Output "`n.NET 8.0 Desktop Runtime Info`n-----"
  Write-Output "Installed: $CurrentVersion"
  Write-Output "Latest: $($LatestDotNet.Version)"

  if ($CurrentVersion -is [system.array]) { $CurrentVersion = $CurrentVersion[0] }
  if ($CurrentVersion -lt $LatestDotNet.Version) {
    
    # Download installer
    Write-Output "`n.NET 8.0 Desktop Runtime installation needed"
    Write-Output 'Downloading...'
    $Installer = Join-Path -Path $env:TEMP -ChildPath (Split-Path $LatestDotNet.URL -Leaf)
    Invoke-WebRequest -Uri $LatestDotNet.URL -OutFile $Installer

    # Verify SHA512 checksum
    if ($null -ne $LatestDotNet.Checksum) {
      Write-Output 'Verifying SHA512 checksum...'
      $InstallerChecksum = (Get-FileHash -Path $Installer -Algorithm SHA512).Hash
      if ($InstallerChecksum -ne $LatestDotNet.Checksum) {
        Write-Warning 'SHA512 checksum verification failed - aborting...'
        Remove-Item $Installer -Force -ErrorAction Ignore
        exit 1
      }
    }
    else { Write-Warning 'Unable to retrieve checksum from Microsoft for validation - skipping...' }
    
    # Install .NET
    Write-Output 'Installing...'
    Start-Process -Wait -NoNewWindow -FilePath $Installer -ArgumentList '/install /quiet /norestart'

    # Confirm installation
    $CurrentVersion = (Get-InstalledApps -DisplayName "Microsoft Windows Desktop Runtime*($Arch)").BundleVersion | Where-Object { $_ -like '8.*' }
    if ($CurrentVersion -is [system.array]) { $CurrentVersion = $CurrentVersion[0] }
    if ($CurrentVersion -match $LatestDotNet.Version) {
      Write-Output "Successfully installed .NET 8.0 Desktop Runtime [$CurrentVersion]"
      Remove-Item $Installer -Force -ErrorAction Ignore 
    }
    else {
      Write-Warning ".NET 8.0 Desktop Runtime [$($LatestDotNet.Version)] not detected after installation attempt"
      Remove-Item $Installer -Force -ErrorAction Ignore 
      exit 1
    }
  }
  elseif ($null -eq $LatestDotNet.Version) { 
    Write-Output "`nUnable to retrieve latest .NET 8.0 Desktop Runtime version - skipping installation / upgrade"
  }
  else { Write-Output "`n.NET 8.0 Desktop Runtime installation / upgrade not needed" }
}

function Invoke-DellCommandUpdate {
  # Check for DCU CLI
  $DCU = (Resolve-Path "$env:SystemDrive\Program Files*\Dell\CommandUpdate\dcu-cli.exe").Path
  if ($null -eq $DCU) {
    Write-Warning 'Dell Command Update CLI was not detected.'
    exit 1
  }
  
  try {
    # Configure DCU automatic updates
    Start-Process -NoNewWindow -Wait -FilePath $DCU -ArgumentList '/configure -scheduleAction=DownloadInstallAndNotify -updatesNotification=disable -forceRestart=disable -scheduleAuto -silent'
    
    # Install updates
    Start-Process -NoNewWindow -Wait -FilePath $DCU -ArgumentList '/applyUpdates -autoSuspendBitLocker=enable -reboot=disable'
  }
  catch {
    Write-Warning 'Unable to apply updates using the dcu-cli.'
    Write-Warning $_
    exit 1
  }
}

# Override switch params from NinjaOne script variables
if ($env:Reboot -and [System.Convert]::ToBoolean($env:Reboot)) { $Reboot = $true }

# Set PowerShell preferences
Set-Location -Path $env:SystemRoot
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
if ([Net.ServicePointManager]::SecurityProtocol -notcontains 'Tls12' -and [Net.ServicePointManager]::SecurityProtocol -notcontains 'Tls13') {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Check device manufacturer
if ((Get-CimInstance -ClassName Win32_BIOS).Manufacturer -notlike '*Dell*') {
  Write-Output "`nNot a Dell system. Aborting..."
  exit 0
}

# Handle Prerequisites / Dependencies
$Arch = Get-Architecture
Remove-DellUpdateApps -DisplayNames 'Dell Update'
Install-DotNetDesktopRuntime

# Install DCU and available updates
Install-DellCommandUpdate
Invoke-DellCommandUpdate

# Reboot if specified
if ($Reboot) {
  Write-Warning 'Reboot specified - rebooting in 60 seconds...'
  Start-Process -Wait -NoNewWindow -FilePath 'shutdown.exe' -ArgumentList '/r /f /t 60 /c "This system will restart in 60 seconds to install driver and firmware updates. Please save and close your work." /d p:4:1'
}
else { Write-Output "`nA reboot may be needed to complete the installation of driver and firmware updates." }
