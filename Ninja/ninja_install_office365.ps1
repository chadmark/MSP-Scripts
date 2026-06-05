<#
  .SYNOPSIS
    Installs Microsoft Office 365 (64-bit) via the Office Deployment Tool.
  .DESCRIPTION
    Downloads the latest Office Deployment Tool from Microsoft, then installs
    Microsoft 365 Apps using either a provided configuration XML or a built-in
    default. Always enforces 64-bit installation. Removes the Microsoft Office
    Hub Store app post-install and adds desktop shortcuts for Word, Excel, and
    Outlook (classic).

    WARNING: The default configuration XML will remove all existing Office
    installations via RemoveMSI. If using a custom XML, ensure it is correct
    before running.
  .PARAMETER Config
    Parameter Set: Custom
    URL or file path to a custom configuration XML for Office installation.
  .NOTES
    Author:      Chad Markley
    Last Edit:   04-15-2026
    GitHub:      https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_install_office365.ps1
    Environment: NinjaOne RMM — runs as SYSTEM on Windows endpoints
    Requires:    PowerShell 5.1+, internet access to Microsoft download servers
    Version:     1.0

    Original Author: Aaron J. Stevenson
    Original Link:   https://github.com/NinjaRMM/NinjaDocs
  .LINK
    https://github.com/chadmark/MSP-Scripts
  .LINK
    XML Configuration Generator: https://config.office.com/
  .LINK
    Supported Product IDs: https://learn.microsoft.com/en-us/microsoft-365/troubleshoot/installation/product-ids-supported-office-deployment-click-to-run
#>

[CmdletBinding()]
param (
  [Parameter()]
  [Alias('Configure')][String]$Config
)

function Test-ValidUrl {
  param([String]$Url)
  try {
    $Uri = [System.Uri]::New($Url)
    return $Uri.Scheme -in @('http', 'https')
  }
  catch {
    return $false
  }
}

function Get-ODT {
  Write-Output "`nRetrieving Office Deployment Tool download URL..."
  [String]$MSWebPage = Invoke-RestMethod 'https://www.microsoft.com/en-us/download/details.aspx?id=49117'
  $Script:ODTURL = $MSWebPage | ForEach-Object {
    if ($_ -match '.*href="(https://download.microsoft.com.*officedeploymenttool.*\.exe)"') { $Matches[1] }
  }

  if (-not $Script:ODTURL) {
    Write-Warning 'Could not determine ODT download URL. Microsoft may have changed their download page structure.'
    exit 1
  }

  try {
    Write-Output "Downloading Office Deployment Tool (ODT)..."
    Invoke-WebRequest -Uri $Script:ODTURL -OutFile $Script:Installer
    Start-Process -Wait -NoNewWindow -FilePath $Script:Installer -ArgumentList "/extract:$Script:ODT /quiet"
  }
  catch {
    Remove-Item $Script:ODT, $Script:Installer -Recurse -Force -ErrorAction Ignore
    Write-Warning 'There was an error downloading the Office Deployment Tool.'
    Write-Warning $_
    exit 1
  }
}

function Set-ConfigXML {
  $Path = Split-Path -Path $Script:ConfigFile -Parent
  if (!(Test-Path -Path $Path -PathType Container)) {
    New-Item -Path $Path -ItemType Directory | Out-Null
  }

  switch ($Config) {
    { ($_) -and (Test-Path -Path $_ -PathType Leaf -Include '*.xml') } { $ConfigPath = $true }
    { ($_) -and (Test-ValidUrl -Url $_) } { $ConfigUrl = $true }
    default { $DefaultConfig = $true }
  }

  if ($ConfigPath) {
    Write-Output 'Configuration file path provided — copying to temp directory...'
    try { Copy-Item -Path $Config -Destination $Script:ConfigFile }
    catch {
      Write-Warning 'Unable to copy configuration file.'
      Write-Warning $_
      exit 1
    }
  }

  if ($ConfigUrl) {
    Write-Output 'Configuration URL provided — downloading to temp directory...'
    try { Invoke-WebRequest -Uri $Config -OutFile $Script:ConfigFile }
    catch {
      Write-Warning 'Unable to download configuration file.'
      Write-Warning $_
      exit 1
    }
  }

  if ($DefaultConfig) {
    Write-Output 'No configuration provided — using built-in default XML...'
    try {
      $XML = [XML]@'
<Configuration ID="e12c359d-194d-49ec-9cb3-b1858d52bbf7">
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise" MigrateArch="TRUE">
    <Product ID="O365BusinessRetail">
      <Language ID="MatchOS" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
      <ExcludeApp ID="OneNote" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="DeviceBasedLicensing" Value="0" />
  <Property Name="SCLCacheOverride" Value="0" />
  <Property Name="PinIconsToTaskbar" Value="TRUE" />
  <Updates Enabled="TRUE" />
  <RemoveMSI>
    <IgnoreProduct ID="VisPro" />
    <IgnoreProduct ID="VisStd" />
  </RemoveMSI>
  <AppSettings>
    <Setup Name="Company" Value="Company Name" />
    <User Key="software\microsoft\office\16.0\excel\options" Name="defaultformat" Value="51" Type="REG_DWORD" App="excel16" Id="L_SaveExcelfilesas" />
    <User Key="software\microsoft\office\16.0\powerpoint\options" Name="defaultformat" Value="27" Type="REG_DWORD" App="ppt16" Id="L_SavePowerPointfilesas" />
    <User Key="software\microsoft\office\16.0\word\options" Name="defaultformat" Value="" Type="REG_SZ" App="word16" Id="L_SaveWordfilesas" />
    <User Key="software\microsoft\office\16.0\firstrun" Name="bootedrtm" Value="1" Type="REG_DWORD" App="office16" Id="L_DisableOfficeFirstrun" />
  </AppSettings>
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@

      # Enforce 64-bit regardless of OS architecture
      $AddNode = $XML.SelectSingleNode('//Add[@OfficeClientEdition]')
      $AddNode.SetAttribute('OfficeClientEdition', '64')
      Write-Output 'Enforcing 64-bit Office installation.'

      $XML.Save("$Script:ConfigFile")
    }
    catch {
      Write-Warning 'Unable to create default configuration file.'
      Write-Warning $_
      exit 1
    }
  }
}

function Install-Office {
  Write-Output 'Installing Microsoft Office 365...'
  try {
    Start-Process -Wait -WindowStyle Hidden -FilePath "$Script:ODT\setup.exe" -ArgumentList "/configure $Script:ConfigFile"
    Write-Output 'Office installation complete.'
  }
  catch {
    Write-Warning 'Error during Office installation:'
    Write-Warning $_
  }
  finally {
    Remove-Item $Script:ODT, $Script:Installer -Recurse -Force -ErrorAction Ignore
  }
}

function Remove-OfficeHub {
  $AppName = 'Microsoft.MicrosoftOfficeHub'
  try {
    $Package = Get-AppxPackage -AllUsers | Where-Object { $AppName -contains $_.Name }
    $ProvisionedPackage = Get-AppxProvisionedPackage -Online | Where-Object { $AppName -contains $_.DisplayName }
    if ($Package -or $ProvisionedPackage) {
      Write-Output "`nRemoving [$AppName] (Microsoft Store App)..."
      $ProvisionedPackage | Remove-AppxProvisionedPackage -AllUsers | Out-Null
      $Package | Remove-AppxPackage -AllUsers
    }
  }
  catch {
    Write-Warning "Error during [$AppName] removal:"
    Write-Warning $_
  }
}

function Add-DesktopShortcuts {
  $Shortcuts = @(
    @{ Name = 'Excel';             Source = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Excel.lnk' },
    @{ Name = 'Outlook (classic)'; Source = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Outlook (classic).lnk' },
    @{ Name = 'Word';              Source = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Word.lnk' }
  )

  $Destination = 'C:\Users\Public\Desktop\'

  foreach ($Shortcut in $Shortcuts) {
    if (Test-Path -Path $Shortcut.Source) {
      try {
        Copy-Item -Path $Shortcut.Source -Destination $Destination -Force
        Write-Output "Shortcut added: $($Shortcut.Name)"
      }
      catch {
        Write-Warning "Failed to copy shortcut for $($Shortcut.Name):"
        Write-Warning $_
      }
    }
    else {
      Write-Warning "Shortcut not found (skipping): $($Shortcut.Source)"
    }
  }
}

# --- Main ---

$Script:ODT        = "$env:temp\ODT"
$Script:ConfigFile = "$Script:ODT\office-config.xml"
$Script:Installer  = "$env:temp\ODTSetup.exe"

$ProgressPreference    = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

if ([Net.ServicePointManager]::SecurityProtocol -notcontains 'Tls12' -and
    [Net.ServicePointManager]::SecurityProtocol -notcontains 'Tls13') {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

Get-ODT
Set-ConfigXML
Install-Office
Remove-OfficeHub
Add-DesktopShortcuts
