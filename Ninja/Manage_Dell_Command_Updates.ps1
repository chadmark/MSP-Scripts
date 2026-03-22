#Requires -Version 5.1

<#
===============================================================================
SCRIPT:      Manage Dell Command Updates.ps1
AUTHOR:      Chad Mark
PLATFORM:    NinjaRMM
REPOSITORY:  https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/Manage_Dell_Command_Updates.ps1
CREATED:     03/21/2026
UPDATED:     03/21/2026

DESCRIPTION:
    Manages Dell Command Update (DCU) on Dell systems. Scans for available
    BIOS, firmware, driver, and application updates, reports them to NinjaRMM
    custom fields, and optionally installs them. If DCU or .NET 8 are not
    installed, the script can install them automatically.

    Must be run as SYSTEM. Dell systems only.

USAGE (NinjaRMM Script Variables):
    InstallDCUAndDotNet8IfNeeded      - Checkbox. Install DCU and .NET 8 Desktop
                                        Runtime if not already present
    InstallAllUpdates                 - Checkbox. Install all available updates.
                                        Overrides all other Install options
    SuspendBitLockerAndRebootIfNeeded - Checkbox. If a reboot is required after
                                        an update, suspend BitLocker and reboot

    DestinationFolderPath             - Optional. Folder for output/log files.
                                        Defaults to: C:\ProgramData\Dell\UpdateService
    SortUpdatesBy                     - Optional. Sort update list by: Name | Type |
                                        Category | ReleaseDate | Severity (default)
    WysiwygCustomFieldName            - Optional. NinjaRMM WYSIWYG custom field to
                                        populate with available updates list
    MultilineCustomFieldName          - Optional. NinjaRMM multiline custom field to
                                        populate with available updates list
    InstallUpdatesByPackageID         - Optional. Comma-separated list of 5-char
                                        package IDs to install (e.g. "G7K77,NJKY9")
    InstallUpdatesByCategory          - Optional. Install updates by a single category
                                        (e.g. "Security")
    InstallUpdatesBySeverity          - Optional. Install updates by severity:
                                        Recommended | Urgent | Optional
    InstallUpdatesByType              - Optional. Install updates by type:
                                        BIOS | Firmware | Driver | Application

NOTES:
    - Must run as SYSTEM account
    - Dell systems only - will exit with error on non-Dell hardware
    - Minimum OS: Windows 10
    - .NET 8 Desktop Runtime (64-bit) v8.0.8 or higher is required by DCU
    - InstallAllUpdates overrides all other Install* parameters
    - InstallUpdatesByPackageID overrides Category, Severity, and Type filters
    - Find package IDs by running: dcu-cli.exe /scan in the DCU install folder

CHANGE LOG:
    03/21/2026 - Added standard header block with repository link
    03/21/2026 - Added Dell Client Management Service check: ensures service is
                 set to Automatic and running before proceeding; starts it if
                 stopped/disabled and waits 15 seconds for initialization;
                 also waits 15 seconds when service is already running to allow
                 DCU application to fully initialize before CLI commands are run
                 (fixes exit code 3005 - application initializing error)
    03/21/2026 - Removed hardcoded DCU version 5.5.0 fallback; replaced with
                 Get-LatestDCUFromCatalog which dynamically scans Dell's SKU
                 catalogs to find the true latest version — no more stale URLs
                 or hashes baked into the script
===============================================================================
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$DestinationFolderPath,
    [Parameter()]
    [switch]$InstallDCUAndDotNet8IfNeeded = [System.Convert]::ToBoolean($env:InstallDCUAndDotNet8IfNeeded),
    [Parameter()]
    [string]$SortUpdatesBy = "Severity",
    [Parameter()]
    [string]$WysiwygCustomFieldName,
    [Parameter()]
    [string]$MultilineCustomFieldName,
    [Parameter()]
    [switch]$InstallAllUpdates = [System.Convert]::ToBoolean($env:InstallAllUpdates),
    [Parameter()]
    [string]$InstallUpdatesByPackageID,
    [Parameter()]
    [string]$InstallUpdatesByCategory,
    [Parameter()]
    [string]$InstallUpdatesBySeverity,
    [Parameter()]
    [string]$InstallUpdatesByType,
    [Parameter()]
    [switch]$SuspendBitLockerAndRebootIfNeeded = [System.Convert]::ToBoolean($env:SuspendBitLockerAndRebootIfNeeded)
)

begin {
    Write-Host ""

    if ([System.Environment]::OSVersion.Version.Build -lt 10240) {
        Write-Host -Object "[Warning] The minimum OS version supported by this script is Windows 10 (10240)."
        Write-Host -Object "[Warning] OS build '$([System.Environment]::OSVersion.Version.Build)' detected. This could lead to errors or unexpected results.`n"
    }

    if ($env:DestinationFolderPath) { $DestinationFolderPath = $env:DestinationFolderPath }
    if ($env:SortUpdatesBy) { $SortUpdatesBy = $env:SortUpdatesBy }
    if ($env:WysiwygCustomFieldName) { $WysiwygCustomFieldName = $env:WysiwygCustomFieldName }
    if ($env:MultilineCustomFieldName) { $MultilineCustomFieldName = $env:MultilineCustomFieldName }
    if ($env:InstallUpdatesByPackageID) { $InstallUpdatesByPackageID = $env:InstallUpdatesByPackageID }
    if ($env:InstallUpdatesByCategory) { $InstallUpdatesByCategory = $env:InstallUpdatesByCategory }
    if ($env:InstallUpdatesBySeverity) { $InstallUpdatesBySeverity = $env:InstallUpdatesBySeverity }
    if ($env:InstallUpdatesByType) { $InstallUpdatesByType = $env:InstallUpdatesByType }

    if ($DestinationFolderPath) {
        $DestinationFolderPath = $DestinationFolderPath.Trim()
        if ([string]::IsNullOrWhiteSpace($DestinationFolderPath)) {
            Write-Host -Object "[Error] The 'Destination Folder Path' parameter contains only spaces. Please provide a valid folder path or leave it blank to use the default of '$env:ProgramData\Dell\CommandUpdate_Ninja'."
            exit 1
        }
        if ($DestinationFolderPath -match '[/*?"<>|]' -or $DestinationFolderPath.SubString(3) -match "[:]") {
            Write-Host -Object "[Error] The 'Destination Folder Path' of '$DestinationFolderPath' contains one of the following invalid characters: '/*?`"<>|:'"
            exit 1
        }
        if ($DestinationFolderPath -notmatch "^[a-zA-Z]:\\") {
            Write-Host -Object "[Error] The 'Destination Folder Path' of '$DestinationFolderPath' is not valid. Please provide a full folder path starting with a drive letter, for example: C:\Folder\Subfolder."
            exit 1
        }
        $ForbiddenFolderPaths = @($env:WinDir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:SystemDrive\Users\Public", $env:ProgramData, "$env:ProgramData\UpdateService\Clients")
        foreach ($ForbiddenFolderPath in $ForbiddenFolderPaths) {
            $ForbiddenFolderRegex = "^$([regex]::Escape($ForbiddenFolderPath))($|\\)"
            if ($DestinationFolderPath -match $ForbiddenFolderRegex -and $DestinationFolderPath -notmatch "^$([regex]::Escape($env:ProgramData))\\Dell($|\\)") {
                Write-Host -Object "[Error] The 'Destination Folder Path' of '$DestinationFolderPath' is not allowed. Please choose a different folder path."
                exit 1
            }
        }
        if ($DestinationFolderPath -match "\\$") { $DestinationFolderPath = $DestinationFolderPath.TrimEnd("\") }
    }
    else {
        $DestinationFolderPath = "$env:ProgramData\Dell\UpdateService"
    }

    if ($SortUpdatesBy -notin @("Name", "Type", "Category", "ReleaseDate", "Severity")) {
        Write-Host -Object "[Error] The 'Sort Updates By' value of '$SortUpdatesBy' is invalid. It must be one of the following values: Name, Type, Category, ReleaseDate, Severity."
        exit 1
    }

    if ($WysiwygCustomFieldName) {
        $WysiwygCustomFieldName = $WysiwygCustomFieldName.Trim()
        if ([string]::IsNullOrWhiteSpace($WysiwygCustomFieldName)) {
            Write-Host -Object "[Error] The 'WYSIWYG Custom Field Name' parameter contains only spaces. Please provide a valid field name or leave it blank."
            exit 1
        }
        if ($WysiwygCustomFieldName -match "[^0-9A-Z]") {
            Write-Host -Object "[Error] The 'WYSIWYG Custom Field Name' of '$WysiwygCustomFieldName' contains invalid characters."
            Write-Host -Object "[Error] Please provide a valid WYSIWYG custom field name to save the results, or leave it blank."
            Write-Host -Object "[Error] https://ninjarmm.zendesk.com/hc/en-us/articles/360060920631-Custom-Field-Setup"
            exit 1
        }
    }

    if ($MultilineCustomFieldName) {
        $MultilineCustomFieldName = $MultilineCustomFieldName.Trim()
        if ([string]::IsNullOrWhiteSpace($MultilineCustomFieldName)) {
            Write-Host -Object "[Error] The 'Multiline Custom Field Name' parameter contains only spaces. Please provide a valid field name or leave it blank."
            exit 1
        }
        if ($MultilineCustomFieldName -match "[^0-9A-Z]") {
            Write-Host -Object "[Error] The 'Multiline Custom Field Name' of '$MultilineCustomFieldName' contains invalid characters."
            Write-Host -Object "[Error] Please provide a valid Multiline custom field name to save the results, or leave it blank."
            Write-Host -Object "[Error] https://ninjarmm.zendesk.com/hc/en-us/articles/360060920631-Custom-Field-Setup"
            exit 1
        }
    }

    if ($InstallAllUpdates -and ($InstallUpdatesByPackageID -or $InstallUpdatesByCategory -or $InstallUpdatesBySeverity -or $InstallUpdatesByType)) {
        Write-Host -Object "[Warning] Only the 'Install All Updates' parameter will be used. All other 'Install' parameters will be ignored."
        $InstallUpdatesByPackageID = $null; $InstallUpdatesByCategory = $null
        $InstallUpdatesBySeverity = $null; $InstallUpdatesByType = $null
    }

    if ($InstallUpdatesByPackageID -and ($InstallUpdatesByCategory -or $InstallUpdatesBySeverity -or $InstallUpdatesByType)) {
        Write-Host -Object "[Warning] Only the 'Install Updates By Package ID' parameter will be used. All other 'Install' parameters will be ignored."
        $InstallUpdatesByCategory = $null; $InstallUpdatesBySeverity = $null; $InstallUpdatesByType = $null
    }

    if ($InstallUpdatesByPackageID) {
        $InstallUpdatesByPackageID = $InstallUpdatesByPackageID.Trim()
        if ([string]::IsNullOrWhiteSpace($InstallUpdatesByPackageID)) {
            Write-Host -Object "[Error] The 'Package IDs to Install' parameter contains only spaces. Please provide a comma-separated list of Package IDs or leave it blank."
            exit 1
        }
        $PackageIDsToParse = $InstallUpdatesByPackageID -split ","
        $ValidatedPackageIDs = New-Object System.Collections.Generic.List[string]
        $InvalidPackageIDs = New-Object System.Collections.Generic.List[string]
        foreach ($PackageID in $PackageIDsToParse) {
            $PackageID = $PackageID.Trim()
            if ($PackageID -match "[^0-9A-Z]") {
                Write-Host -Object "[Warning] The package ID '$PackageID' contains invalid characters. Only alphanumeric characters are allowed."
                $InvalidPackageIDs.Add($PackageID); $AddNewLine = $True; continue
            }
            if ($PackageID -notmatch "^[0-9A-Z]{5}$") {
                Write-Host -Object "[Warning] The package ID '$PackageID' is not valid. Package IDs must be exactly 5 alphanumeric characters."
                $InvalidPackageIDs.Add($PackageID); $AddNewLine = $True; continue
            }
            $ValidatedPackageIDs.Add($PackageID)
        }
        if ($AddNewLine) { Write-Host ""; $AddNewLine = $False }
        if (-not $ValidatedPackageIDs) {
            Write-Host -Object "[Error] No valid package IDs were provided. Please provide a comma-separated list of valid Package IDs or leave it blank."
            exit 1
        }
    }

    if ($InstallUpdatesByCategory) {
        $InstallUpdatesByCategory = $InstallUpdatesByCategory.Trim()
        if ([string]::IsNullOrWhiteSpace($InstallUpdatesByCategory)) {
            Write-Host -Object "[Error] The 'Install Updates By Category' parameter contains only spaces. Please provide a valid category or leave it blank."
            exit 1
        }
        if ($InstallUpdatesByCategory -match "[,;]") {
            Write-Host -Object "[Error] The 'Install Updates By Category' parameter only accepts a single category value. Please provide a valid category or leave it blank."
            exit 1
        }
    }

    if ($InstallUpdatesBySeverity) {
        $InstallUpdatesBySeverity = $InstallUpdatesBySeverity.Trim()
        if ([string]::IsNullOrWhiteSpace($InstallUpdatesBySeverity)) {
            Write-Host -Object "[Error] The 'Install Updates By Severity' parameter contains only spaces. Please provide a valid severity (Recommended, Urgent, Optional) or leave it blank."
            exit 1
        }
        if ($InstallUpdatesBySeverity -match "[,;\s]") {
            Write-Host -Object "[Error] The 'Install Updates By Severity' parameter only accepts a single severity value. Please provide one of the valid severities (Recommended, Urgent, Optional) or leave it blank."
            exit 1
        }
        if ($InstallUpdatesBySeverity -notin @("Recommended", "Urgent", "Optional")) {
            Write-Host -Object "[Error] '$InstallUpdatesBySeverity' is not a valid update severity. Please provide a valid severity (Recommended, Urgent, Optional) or leave it blank."
            exit 1
        }
    }

    if ($InstallUpdatesByType) {
        $InstallUpdatesByType = $InstallUpdatesByType.Trim()
        if ([string]::IsNullOrWhiteSpace($InstallUpdatesByType)) {
            Write-Host -Object "[Error] The 'Install Updates By Type' parameter contains only spaces. Please provide a valid type (BIOS, Firmware, Driver, Application) or leave it blank."
            exit 1
        }
        if ($InstallUpdatesByType -match "[,;\s]") {
            Write-Host -Object "[Error] The 'Install Updates By Type' parameter only accepts a single type value. Please provide one of the valid types (BIOS, Firmware, Driver, Application) or leave it blank."
            exit 1
        }
        if ($InstallUpdatesByType -notin @("BIOS", "Firmware", "Driver", "Application")) {
            Write-Host -Object "[Error] '$InstallUpdatesByType' is not a valid update type. Please provide a valid type (BIOS, Firmware, Driver, Application) or leave it blank."
            exit 1
        }
    }

    #region Helper functions
    function Invoke-Download {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $True)][System.Uri]$URL,
            [Parameter(Mandatory = $True)][String]$Path,
            [Parameter()][int]$Attempts = 3,
            [Parameter()][Switch]$SkipSleep,
            [Parameter()][Switch]$Overwrite,
            [Parameter()][ValidateSet("Chrome", "Edge", "Firefox", "Firefox ESR", "Safari", "InternetExplorer", "Opera")][String]$UserAgent,
            [Parameter()][Switch]$Quiet
        )

        $SupportedTLSversions = [enum]::GetValues('Net.SecurityProtocolType')
        if ( ($SupportedTLSversions -contains 'Tls13') -and ($SupportedTLSversions -contains 'Tls12') ) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol::Tls13 -bor [System.Net.SecurityProtocolType]::Tls12
        } elseif ( $SupportedTLSversions -contains 'Tls12' ) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        } else {
            Write-Host -Object "[Warning] TLS 1.2 and/or TLS 1.3 are not supported on this system. This download may fail!"
            if ($PSVersionTable.PSVersion.Major -lt 3) { Write-Host -Object "[Warning] PowerShell 2 / .NET 2.0 doesn't support TLS 1.2." }
        }

        if ($Path) { $Path = $Path.Trim() }
        if (!$URL) { throw [System.ArgumentNullException]::New("You must provide a URL.") }
        if (!$Path) { throw [System.ArgumentNullException]::New("You must provide a file path.") }

        if ($URL -notmatch "^http") {
            try { $URL = [System.Uri]"https://$URL" }
            catch { throw [System.UriFormatException]::New("[Error] The URL '$($URL.OriginalString)' is not valid.") }
            Write-Host -Object "[Warning] The URL given is missing http(s). Modified to: '$($URL.AbsoluteUri)'."
        } elseif (-not $Quiet) { Write-Host -Object "URL '$($URL.AbsoluteUri)' was given." }

        if ($Path -and ($Path -match '[/*?"<>|]' -or ($Path.Length -ge 2 -and $Path.Substring(2) -match "[:]"))) {
            throw [System.IO.InvalidDataException]::New("[Error] The file path specified '$Path' contains invalid characters.")
        }

        $Path -split '\\' | ForEach-Object {
            $Folder = ($_).Trim()
            if ($Folder -match '^(CON|PRN|AUX|NUL)$' -or $Folder -match '^(LPT|COM)\d+$') {
                throw [System.IO.InvalidDataException]::New("[Error] An invalid folder name was given in '$Path'.")
            }
        }

        $PreviousProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'

        if (($Path | Split-Path -Leaf) -notmatch "[.]") {
            if (-not $Quiet) { Write-Host -Object "No filename provided in '$Path'. Checking the URL for a suitable filename." }
            $AbsolutePath = $URL.AbsolutePath
            if ($AbsolutePath -ne "/" -and $AbsolutePath -ne "") { $ProposedFilename = Split-Path $URL.OriginalString -Leaf }
            if ($ProposedFilename -and $ProposedFilename -notmatch "[^A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]" -and $ProposedFilename -match "[.]") { $Filename = $ProposedFilename }
            if ($PSVersionTable.PSVersion.Major -lt 4) {
                $ProgressPreference = $PreviousProgressPreference
                throw [System.NotSupportedException]::New("You must provide a filename for systems not running PowerShell 4 or higher.")
            }
            if (!$Filename) {
                if (-not $Quiet) { Write-Host -Object "Attempting to discover filename via Content-Disposition header." }
                $Request = 1
                while ($Request -le $Attempts) {
                    if (!($SkipSleep)) { $SleepTime = Get-Random -Minimum 3 -Maximum 15; if (-not $Quiet) { Write-Host -Object "Waiting for $SleepTime seconds." }; Start-Sleep -Seconds $SleepTime }
                    if ($Request -ne 1 -and -not $Quiet) { Write-Host "" }
                    if (-not $Quiet) { Write-Host -Object "Attempt $Request" }
                    try { $HeaderRequest = Invoke-WebRequest -Uri $URL -Method "HEAD" -MaximumRedirection 10 -UseBasicParsing -ErrorAction Stop }
                    catch { Write-Host -Object "[Warning] $($_.Exception.Message)"; Write-Host -Object "[Warning] The header request failed." }
                    if (!$HeaderRequest.Headers."Content-Disposition") { Write-Host -Object "[Warning] The web server did not provide a Content-Disposition header." }
                    else { $Content = [System.Net.Mime.ContentDisposition]::new($HeaderRequest.Headers."Content-Disposition"); $Filename = $Content.FileName }
                    if ($Filename) { $Request = $Attempts }
                    $Request++
                }
            }
            if ($Filename) { $Path = "$Path\$Filename" }
            else { $ProgressPreference = $PreviousProgressPreference; throw [System.IO.FileNotFoundException]::New("Unable to find a suitable filename from the URL.") }
        }

        if ((Test-Path -Path $Path -ErrorAction SilentlyContinue) -and !$Overwrite) {
            $ProgressPreference = $PreviousProgressPreference
            throw [System.IO.IOException]::New("A file already exists at the path '$Path'.")
        }

        $Path = $Path -replace '\\+', '\'
        $DestinationFolder = $Path | Split-Path
        if (!(Test-Path -Path $DestinationFolder -ErrorAction SilentlyContinue)) {
            try {
                if (-not $Quiet) { Write-Host -Object "Attempting to create the folder '$DestinationFolder'." }
                New-Item -Path $DestinationFolder -ItemType "directory" -ErrorAction Stop | Out-Null
                if (-not $Quiet) { Write-Host -Object "Successfully created the folder." }
            } catch { $ProgressPreference = $PreviousProgressPreference; throw $_ }
        }

        if ($UserAgent) {
            $UserAgentString = switch ($UserAgent) {
                "Chrome"           { "Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) AppleWebKit/534.6 (KHTML, like Gecko) Chrome/7.0.500.0 Safari/534.6" }
                "Edge"             { "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36 Edg/139.0.3405.86" }
                "Firefox"          { "Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) Gecko/20100401 Firefox/4.0" }
                "Firefox ESR"      { "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0" }
                "InternetExplorer" { "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT; Windows NT 10.0; en-US)" }
                "Opera"            { "Opera/9.70 (Windows NT; Windows NT 10.0; en-US) Presto/2.2.1" }
                "Safari"           { "Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) AppleWebKit/533.16 (KHTML, like Gecko) Version/5.0 Safari/533.16" }
            }
        }

        if (-not $Quiet) { Write-Host -Object "Downloading the file..." }

        $DownloadAttempt = 1
        while ($DownloadAttempt -le $Attempts) {
            if (!($SkipSleep)) {
                $SleepTime = Get-Random -Minimum 3 -Maximum 15
                if (-not $Quiet) { Write-Host -Object "Waiting for $SleepTime seconds." }
                Start-Sleep -Seconds $SleepTime
            }
            if ($DownloadAttempt -ne 1 -and -not $Quiet) { Write-Host "" }
            if (-not $Quiet) { Write-Host -Object "Download Attempt $DownloadAttempt" }
            try {
                if ($PSVersionTable.PSVersion.Major -lt 4) {
                    $WebClient = New-Object System.Net.WebClient
                    if ($UserAgent) { $WebClient.Headers.Add("User-Agent", $UserAgentString) }
                    $WebClient.DownloadFile($URL, $Path)
                } else {
                    $WebRequestArgs = @{ Uri = $URL; OutFile = $Path; MaximumRedirection = 10; UseBasicParsing = $true }
                    if ($UserAgent) { $WebRequestArgs.Add("UserAgent", $UserAgentString) }
                    Invoke-WebRequest @WebRequestArgs
                }
                $File = Test-Path -Path $Path -ErrorAction SilentlyContinue
            } catch {
                Write-Host -Object "[Warning] An error has occurred while downloading!"
                Write-Host -Object "[Warning] $($_.Exception.Message)"
                if (Test-Path -Path $Path -ErrorAction SilentlyContinue) { Remove-Item $Path -Force -Confirm:$false -ErrorAction SilentlyContinue }
                $File = $False
            }
            if ($File) { $DownloadAttempt = $Attempts }
            elseif ($DownloadAttempts -ne ($Attempts - 1)) { Write-Host -Object "[Warning] File failed to download. Retrying...`n" }
            $DownloadAttempt++
        }

        $ProgressPreference = $PreviousProgressPreference
        if (!(Test-Path $Path)) { throw [System.IO.FileNotFoundException]::New("[Error] Failed to download file. Please verify the URL of '$URL'.") }
        else { return $Path }
    }

    function Get-DellSupportedModels {
        [CmdletBinding()]
        param ([Parameter()][string]$DestinationFolder)

        if ([string]::IsNullOrWhitespace($DestinationFolder)) { throw [System.ArgumentException]::New("A valid DestinationFolder is required.") }

        $SupportedModelsCabPath = "$DestinationFolder\CatalogIndexPC.cab"
        $SupportedModelsXmlPath = "$DestinationFolder\SupportedModels.xml"
        $CatalogURL = "https://downloads.dell.com/catalog/CatalogIndexPC.cab"

        try { Invoke-Download -URL $CatalogURL -Path $SupportedModelsCabPath -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null }
        catch { throw $_ }

        try { Invoke-LegacyConsoleTool -FilePath "expand" -ArgumentList "`"$SupportedModelsCabPath`" `"$SupportedModelsXmlPath`"" -ErrorAction Stop | Out-Null }
        catch { throw $_ }

        if ($LASTEXITCODE -ne 0) { throw [System.Exception]::New("Unable to extract the SupportedModels.xml file.") }
        if (-not (Test-Path $SupportedModelsXmlPath)) { throw [System.IO.FileNotFoundException]::New("SupportedModels.xml not found at '$SupportedModelsXmlPath'.") }

        try { $SupportedModelsXml = Get-Content -Path $SupportedModelsXmlPath -ErrorAction Stop }
        catch { throw [System.Exception]::New("Failed to read SupportedModels.xml.") }

        try { $SupportedModelsXml = [xml]$SupportedModelsXml }
        catch { throw [System.InvalidCastException]::New("Failed to parse SupportedModels.xml.") }

        $SupportedModelsObject = New-Object System.Collections.Generic.List[PSObject]
        foreach ($Model in $SupportedModelsXml.ManifestIndex.GroupManifest) {
            $SupportedModelsObject.Add([PSCustomObject]@{
                SKU     = $Model.SupportedSystems.Brand.Model.systemID
                Brand   = $Model.SupportedSystems.Brand.Display."#cdata-section"
                Model   = $Model.SupportedSystems.Brand.Model.Display."#cdata-section"
                URL     = $Model.ManifestInformation.path
                Version = $Model.ManifestInformation.version
            })
        }
        return $SupportedModelsObject
    }

    function Get-DellAvailableUpdates {
        [CmdletBinding()]
        param (
            [Parameter()][string]$SystemSKU,
            [Parameter()][string]$Method,
            [Parameter()][string]$DestinationFolder,
            [Parameter()][switch]$Latest
        )

        if ([string]::IsNullOrWhiteSpace($Method)) { throw [System.ArgumentException]::New("A method is required. Please provide either 'CatalogDownload' or 'CLI'.") }
        if ($Method -notin @("CatalogDownload", "CLI")) { throw [System.ArgumentException]::New("Invalid method '$Method'. Valid methods are 'CatalogDownload' and 'CLI'.") }
        if ([string]::IsNullOrWhitespace($DestinationFolder)) { throw [System.ArgumentException]::New("A valid DestinationFolder is required.") }

        if ($Method -eq "CatalogDownload") {
            if ([string]::IsNullOrWhiteSpace($SystemSKU)) { throw [System.ArgumentException]::New("A SystemSKU is required when using the CatalogDownload method.") }

            if (-not $SupportedModels) {
                try { $SupportedModels = Get-DellSupportedModels -DestinationFolder $DestinationFolder -ErrorAction Stop }
                catch { throw $_ }
            }

            $UpdateURL = ($SupportedModels | Where-Object { $_.SKU -eq $SystemSKU }).URL
            if ([string]::IsNullOrWhiteSpace($UpdateURL)) { throw [System.Exception]::New("Could not find an update catalog for SKU '$SystemSKU'.") }

            $UpdatesFromCatalogCabPath = "$DestinationFolder\CatalogIndexModel.cab"
            $UpdatesFromCatalogXMLPath = "$DestinationFolder\UpdatesFromCatalog.xml"

            try { Invoke-Download -URL "https://downloads.dell.com/$UpdateURL" -Path $UpdatesFromCatalogCabPath -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null }
            catch { throw $_ }

            try { Invoke-LegacyConsoleTool -FilePath "expand" -ArgumentList "`"$UpdatesFromCatalogCabPath`" `"$UpdatesFromCatalogXMLPath`"" -ErrorAction Stop | Out-Null }
            catch { throw [System.Exception]::New("Unable to extract UpdatesFromCatalog.xml for SKU '$ComputerSKU'.") }

            if ($LASTEXITCODE -ne 0) { throw [System.Exception]::New("Unable to extract UpdatesFromCatalog.xml for SKU '$ComputerSKU'.") }
            if (-not (Test-Path $UpdatesFromCatalogXMLPath)) { throw [System.IO.FileNotFoundException]::New("UpdatesFromCatalog.xml not found at '$UpdatesFromCatalogXMLPath'.") }

            try { $UpdatesFromCatalogXML = Get-Content -Path $UpdatesFromCatalogXMLPath -ErrorAction Stop }
            catch { throw [System.Exception]::New("Failed to read UpdatesFromCatalog.xml for SKU '$ComputerSKU'.") }

            try { $UpdatesFromCatalogXML = [xml]$UpdatesFromCatalogXML }
            catch { throw [System.InvalidCastException]::New("Failed to parse UpdatesFromCatalog.xml.") }

            $AvailableUpdatesList = New-Object System.Collections.Generic.List[PSObject]
            $BaseUpdateURL = $UpdatesFromCatalogXML.Manifest.baseLocation

            foreach ($Update in $UpdatesFromCatalogXML.Manifest.SoftwareComponent) {
                $AvailableUpdatesList.Add([PSCustomObject]@{
                    PackageID          = $Update.packageID
                    Name               = $Update.Name.Display."#cdata-section"
                    Type               = $Update.ComponentType.Display."#cdata-section"
                    Category           = $Update.Category.Display."#cdata-section"
                    DellVersion        = $Update.dellVersion
                    VendorVersion      = $Update.VendorVersion
                    PackageType        = $Update.PackageType
                    ReleaseDate        = ([datetime]$Update.releaseDate).ToShortDateString()
                    Description        = $Update.Description.Display."#cdata-section"
                    DownloadURL        = "https://$BaseUpdateURL/$($Update.path)"
                    DownloadHashSha256 = ($Update.Cryptography.Hash | Where-Object { $_.algorithm -eq "SHA256" })."#text"
                    DownloadHashMD5    = ($Update.Cryptography.Hash | Where-Object { $_.algorithm -eq "MD5" })."#text"
                    DownloadHashSha1   = ($Update.Cryptography.Hash | Where-Object { $_.algorithm -eq "SHA1" })."#text"
                    Severity           = $Update.Criticality.Display."#cdata-section"
                })
            }

            if ($Latest) {
                $AvailableUpdatesList = $AvailableUpdatesList | Group-Object Name | ForEach-Object { $_.Group | Sort-Object { [datetime]::Parse($_.ReleaseDate) } -Descending | Select-Object -First 1 }
            }
        }

        if ($Method -eq "CLI") {
            if (Test-Path "$env:ProgramData\Dell\UpdateService\Temp\Inventory.xml") {
                try { Remove-Item -Path "$env:ProgramData\Dell\UpdateService\Temp\Inventory.xml" -Force -ErrorAction Stop }
                catch { throw [System.Exception]::New("Unable to remove existing Inventory.xml.`n$($_.Exception.Message)") }

                try { Restart-Service -Name "DellClientManagementService" -Force -ErrorAction Stop | Out-Null }
                catch { throw [System.Exception]::New("Unable to restart the Dell Client Management Service.`n$($_.Exception.Message)") }
            }

            $ScannedUpdatesXMLPath = "$DestinationFolder\DCUApplicableUpdates.xml"
            $ScannedUpdatesLogFilePath = "$DestinationFolder\DCUScan.log"

            try {
                $DCUCLIArguments = "/scan -silent -report=`"$DestinationFolder`" -outputLog=`"$ScannedUpdatesLogFilePath`""
                Invoke-LegacyConsoleTool -FilePath $DCUCLIPath -ArgumentList $DCUCLIArguments -ErrorAction Stop | Out-Null
            }
            catch { throw $_ }

            switch ($LASTEXITCODE) {
                0   {}
                5   { throw [System.Exception]::New("Unable to scan: reboot is required. Please reboot and run the script again.") }
                6   { throw [System.Exception]::New("Dell Command Update is already running. Please stop other instances and run again.") }
                107 { throw [System.Exception]::New("Dell Command Update rejected command line arguments. Check destination folder.") }
                500 {}
                default { throw [System.Exception]::New("Dell Command Update scan exited with code $LASTEXITCODE.") }
            }

            if (-not (Test-Path $ScannedUpdatesXMLPath)) { throw [System.IO.FileNotFoundException]::New("DCUApplicableUpdates.xml not found at '$ScannedUpdatesXMLPath'.") }

            try { $ScannedUpdatesXML = Get-Content -Path "$ScannedUpdatesXMLPath" -ErrorAction Stop }
            catch { throw [System.Exception]::New("Failed to read scan results at '$ScannedUpdatesXMLPath'.") }

            try { $ScannedUpdatesXML = [xml]$ScannedUpdatesXML }
            catch { throw [System.InvalidCastException]::New("Failed to parse scan results at '$ScannedUpdatesXMLPath'.") }

            try { [xml]$ScannedUpdatesXML = Get-Content -Path "$ScannedUpdatesXMLPath" -ErrorAction Stop }
            catch { throw $_ }

            $AvailableUpdatesList = New-Object System.Collections.Generic.List[PSObject]
            foreach ($Update in $ScannedUpdatesXML.updates.update) {
                $AvailableUpdatesList.Add([PSCustomObject]@{
                    PackageID   = $Update.release
                    Name        = $Update.name
                    Type        = $Update.type
                    Category    = $Update.category
                    Version     = $Update.version
                    ReleaseDate = ([datetime]$Update.date).ToShortDateString()
                    DownloadURL = "https://downloads.dell.com/$($Update.file)"
                    Severity    = $Update.urgency
                    Size        = $Update.bytes
                    Status      = "Not installed"
                })
            }
        }

        switch ($SortUpdatesBy) {
            "Name"        { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object Name }
            "Type"        { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object Type, Name }
            "Category"    { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object Category, Name }
            "ReleaseDate" { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object @{ Expression = { Get-Date $_.ReleaseDate }; Descending = $True }, Name }
            "Severity"    { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object @{Expression = { if ($_.Severity -match "Urgent") { 1 } elseif ($_.Severity -eq "Recommended") { 2 } elseif ($_.Severity -eq "Optional") { 3 } } }, Name }
        }

        return $AvailableUpdatesList
    }

    function Invoke-LegacyConsoleTool {
        [CmdletBinding()]
        param(
            [Parameter()][String]$FilePath,
            [Parameter()][String[]]$ArgumentList,
            [Parameter()][String]$WorkingDirectory,
            [Parameter()][Int]$Timeout = 30,
            [Parameter()][System.Text.Encoding]$Encoding
        )

        if ([String]::IsNullOrEmpty($FilePath) -or $FilePath -match "^\s+$") { throw (New-Object System.ArgumentNullException("You must provide a file path.")) }

        if ($WorkingDirectory) {
            if ([String]::IsNullOrWhiteSpace($WorkingDirectory)) { throw (New-Object System.ArgumentNullException("The working directory is just whitespace.")) }
            $WorkingDirectory = $WorkingDirectory.Trim()
            if (!(Test-Path -Path $WorkingDirectory -PathType Container -ErrorAction SilentlyContinue)) { throw (New-Object System.IO.FileNotFoundException("Unable to find '$WorkingDirectory'.")) }
        }

        if (!$Timeout) { throw (New-Object System.ArgumentNullException("You must provide a timeout value.")) }

        if (!([System.IO.Path]::IsPathRooted($FilePath)) -and !(Test-Path -Path $FilePath -PathType Leaf -ErrorAction SilentlyContinue)) {
            $EnvPaths = [System.Environment]::GetEnvironmentVariable("PATH").Split(";")
            $PathExts = [System.Environment]::GetEnvironmentVariable("PATHEXT").Split(";")
            $ResolvedPath = $null
            foreach ($Directory in $EnvPaths) {
                foreach ($FileExtension in $PathExts) {
                    $PotentialMatch = Join-Path $Directory ($FilePath + $FileExtension)
                    if (Test-Path $PotentialMatch -PathType Leaf) { $ResolvedPath = $PotentialMatch; break }
                }
                if ($ResolvedPath) { break }
            }
            if ($ResolvedPath) { $FilePath = $ResolvedPath }
        }

        if (!(Test-Path -Path $FilePath -PathType Leaf -ErrorAction SilentlyContinue)) { throw (New-Object System.IO.FileNotFoundException("Unable to find '$FilePath'.")) }
        if ($Timeout -lt 30) { throw (New-Object System.ArgumentOutOfRangeException("Timeout must be >= 30 seconds.")) }

        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcessInfo.FileName = $FilePath
        if ($ArgumentList) { $ProcessInfo.Arguments = $ArgumentList -join " " }
        $ProcessInfo.UseShellExecute = $False
        $ProcessInfo.CreateNoWindow = $True
        $ProcessInfo.RedirectStandardInput = $True
        $ProcessInfo.RedirectStandardOutput = $True
        $ProcessInfo.RedirectStandardError = $True
        if ($WorkingDirectory) { $ProcessInfo.WorkingDirectory = $WorkingDirectory }

        if (!$Encoding) {
            try {
                if (-not ([System.Management.Automation.PSTypeName]'NativeMethods.Win32').Type) {
                    $Definition = '[DllImport("kernel32.dll")]' + "`n" + 'public static extern uint GetOEMCP();'
                    Add-Type -MemberDefinition $Definition -Name "Win32" -Namespace "NativeMethods" -ErrorAction Stop
                }
                [int]$OemCodePage = [NativeMethods.Win32]::GetOEMCP()
                $Encoding = [System.Text.Encoding]::GetEncoding($OemCodePage)
            } catch { throw $_ }
        }
        $ProcessInfo.StandardOutputEncoding = $Encoding
        $ProcessInfo.StandardErrorEncoding = $Encoding

        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $ProcessInfo
        $Process | Add-Member -MemberType NoteProperty -Name StdOut -Value (New-Object System.Collections.Generic.List[string]) -Force | Out-Null
        $Process | Add-Member -MemberType NoteProperty -Name StdErr -Value (New-Object System.Collections.Generic.List[string]) -Force | Out-Null
        $Process.Start() | Out-Null

        $ProcessTimeout = 0
        $TimeoutInMilliseconds = $Timeout * 1000
        $StdOutBuffer = New-Object System.Text.StringBuilder
        $StdErrBuffer = New-Object System.Text.StringBuilder

        while (!$Process.HasExited -and $ProcessTimeout -lt $TimeoutInMilliseconds) {
            while (!$Process.StandardOutput.EndOfStream -and $Process.StandardOutput.Peek() -ne -1) {
                $Char = $Process.StandardOutput.Read()
                if ($Char -ne -1) {
                    $ActualCharacter = [char]$Char
                    if ($ActualCharacter -eq "`n") { $Process.StdOut.Add($StdOutBuffer.ToString()); $StdOutBuffer.Length = 0 }
                    elseif ($ActualCharacter -ne "`r") { $null = $StdOutBuffer.Append($ActualCharacter) }
                }
            }
            while (!$Process.StandardError.EndOfStream -and $Process.StandardError.Peek() -ne -1) {
                $Char = $Process.StandardError.Read()
                if ($Char -ne -1) {
                    $ActualCharacter = [char]$Char
                    if ($ActualCharacter -eq "`n") { $Process.StdErr.Add($StdErrBuffer.ToString()); $StdErrBuffer.Length = 0 }
                    elseif ($ActualCharacter -ne "`r") { $null = $StdErrBuffer.Append($ActualCharacter) }
                }
            }
            Start-Sleep -Milliseconds 100
            $ProcessTimeout = $ProcessTimeout + 10
        }

        if ($StdOutBuffer.Length -gt 0) { $Process.StdOut.Add($StdOutBuffer.ToString()) }
        if ($StdErrBuffer.Length -gt 0) { $Process.StdErr.Add($StdErrBuffer.ToString()) }

        try {
            if ($ProcessTimeout -ge 300000) { throw (New-Object System.ServiceProcess.TimeoutException("The process has timed out.")) }
            $TimeoutRemaining = 300000 - $ProcessTimeout
            if (!$Process.WaitForExit($TimeoutRemaining)) { throw (New-Object System.ServiceProcess.TimeoutException("The process has timed out.")) }
        } catch {
            if ($Process.ExitCode) { $GLOBAL:LASTEXITCODE = $Process.ExitCode } else { $GLOBAL:LASTEXITCODE = 1 }
            if ($Process) { $Process.Dispose() }
            throw $_
        }

        while (!$Process.StandardOutput.EndOfStream) {
            $Char = $Process.StandardOutput.Read()
            if ($Char -ne -1) {
                $ActualCharacter = [char]$Char
                if ($ActualCharacter -eq "`n") { $Process.StdOut.Add($StdOutBuffer.ToString()); $StdOutBuffer.Length = 0 }
                elseif ($ActualCharacter -ne "`r") { $null = $StdOutBuffer.Append($ActualCharacter) }
            }
        }

        while (!$Process.StandardError.EndOfStream) {
            $Char = $Process.StandardError.Read()
            if ($Char -ne -1) {
                $ActualCharacter = [char]$Char
                if ($ActualCharacter -eq "`n") { $Process.StdErr.Add($StdErrBuffer.ToString()); $StdErrBuffer.Length = 0 }
                elseif ($ActualCharacter -ne "`r") { $null = $StdErrBuffer.Append($ActualCharacter) }
            }
        }

        if ($Process.StdErr.Count -gt 0) {
            if ($Process.ExitCode -or $Process.ExitCode -eq 0) { $GLOBAL:LASTEXITCODE = $Process.ExitCode }
            if ($Process) { $Process.Dispose() }
            $Process.StdErr | Write-Error -Category "FromStdErr"
        }

        if ($Process.StdOut.Count -gt 0) { $Process.StdOut }
        if ($Process.ExitCode -or $Process.ExitCode -eq 0) { $GLOBAL:LASTEXITCODE = $Process.ExitCode }
        if ($Process) { $Process.Dispose() }
    }

    function Get-DotNet8LatestVersion {
        [CmdletBinding()]
        param ()

        $DownloadURL = "https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/8.0/releases.json"
        $DestinationPath = "$env:TEMP\DotNet8Releases.json"

        try { Invoke-Download -URL $DownloadURL -Path "$DestinationPath" -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null }
        catch { throw $_ }

        if (-not (Test-Path "$DestinationPath" -PathType Leaf)) { throw [System.IO.FileNotFoundException]::New("Failed to download .NET 8 releases JSON.") }

        try { $ReleasesJSON = Get-Content "$DestinationPath" -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { throw $_ }

        try { Remove-Item -Path $DestinationPath -Force -ErrorAction Stop }
        catch { Write-Error -Category "CleanupError" -Message "Failed to delete temp file at '$DestinationPath': '$($_.Exception.Message)'" }

        $LatestVersion = $ReleasesJSON."latest-release"
        $LatestReleaseObject = $ReleasesJSON.releases | Where-Object { $_."release-version" -eq $LatestVersion }
        $LatestReleaseDetails = $LatestReleaseObject.windowsdesktop.files | Where-Object { $_.name -match "x64.exe$" }

        return [PSCustomObject]@{
            Version     = $LatestVersion
            DownloadURL = $LatestReleaseDetails.url
            Hash        = $LatestReleaseDetails.hash
        }
    }

    function Get-LatestDCUFromCatalog {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $True)]
            [string]$DestinationFolder
        )

        if ([string]::IsNullOrWhiteSpace($DestinationFolder)) {
            throw [System.ArgumentException]::New("A valid DestinationFolder is required.")
        }

        Write-Host -Object "[Info] Scanning Dell catalogs to find the latest Dell Command Update version available."

        # Re-use SupportedModels if already in memory from earlier in the script
        if (-not $SupportedModels) {
            try {
                $SupportedModels = Get-DellSupportedModels -DestinationFolder $DestinationFolder -ErrorAction Stop
            }
            catch { throw $_ }
        }

        if (-not $SupportedModels) {
            throw [System.Exception]::New("Unable to retrieve the list of supported Dell models.")
        }

        $BestDCUEntry   = $null
        $BestDCUVersion = [version]"0.0.0"
        $CatalogsChecked = 0
        $ModelCabPath   = "$DestinationFolder\DCUScan_Model.cab"
        $ModelXmlPath   = "$DestinationFolder\DCUScan_Model.xml"

        foreach ($Model in $SupportedModels) {
            # After finding a DCU entry, check at least 10 more catalogs to confirm we have the highest version, then stop
            if ($BestDCUEntry -and $CatalogsChecked -ge 10) { break }
            # Hard cap to avoid excessive runtime on edge cases
            if ($CatalogsChecked -ge 75) { break }

            try {
                Invoke-Download -URL "https://downloads.dell.com/$($Model.URL)" -Path $ModelCabPath -Attempts 1 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null
            }
            catch { $CatalogsChecked++; continue }

            try {
                Invoke-LegacyConsoleTool -FilePath "expand" -ArgumentList "`"$ModelCabPath`" `"$ModelXmlPath`"" -ErrorAction Stop | Out-Null
            }
            catch { $CatalogsChecked++; continue }

            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ModelXmlPath -ErrorAction SilentlyContinue)) {
                $CatalogsChecked++
                continue
            }

            try { [xml]$ModelXml = Get-Content -Path $ModelXmlPath -ErrorAction Stop }
            catch { $CatalogsChecked++; continue }

            $DCUEntries = $ModelXml.Manifest.SoftwareComponent | Where-Object {
                $_.Name.Display."#cdata-section" -match "Command.+Windows Universal"
            }

            foreach ($Entry in $DCUEntries) {
                try {
                    $EntryVersion = [version]$Entry.VendorVersion
                    if ($EntryVersion -gt $BestDCUVersion) {
                        $BestDCUVersion = $EntryVersion
                        $BaseURL = $ModelXml.Manifest.baseLocation
                        $BestDCUEntry = [PSCustomObject]@{
                            VendorVersion      = $Entry.VendorVersion
                            DownloadURL        = "https://$BaseURL/$($Entry.path)"
                            DownloadHashSha256 = ($Entry.Cryptography.Hash | Where-Object { $_.algorithm -eq "SHA256" })."#text"
                            DownloadHashSha1   = ($Entry.Cryptography.Hash | Where-Object { $_.algorithm -eq "SHA1" })."#text"
                            DownloadHashMD5    = ($Entry.Cryptography.Hash | Where-Object { $_.algorithm -eq "MD5" })."#text"
                        }
                    }
                }
                catch { continue }
            }

            $CatalogsChecked++
        }

        # Clean up temp files
        foreach ($TempFile in @($ModelCabPath, $ModelXmlPath)) {
            if (Test-Path $TempFile -ErrorAction SilentlyContinue) {
                Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue
            }
        }

        if (-not $BestDCUEntry) {
            throw [System.Exception]::New("Dell Command Update was not found in any of the $CatalogsChecked catalogs checked.")
        }

        Write-Host -Object "[Info] Found Dell Command Update version $($BestDCUEntry.VendorVersion) as the latest available."
        return $BestDCUEntry
    }

    function Test-IsSystem {
        [CmdletBinding()]
        param ()
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return $id.Name -like "NT AUTHORITY*" -or $id.IsSystem
    }

    function Test-IsElevated {
        [CmdletBinding()]
        param ()
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]'544')
    }
    #endregion

    if (!$ExitCode) { $ExitCode = 0 }
}
process {
    try { $IsElevated = Test-IsElevated -ErrorAction Stop }
    catch {
        Write-Host -Object "[Error] $($_.Exception.Message)"
        Write-Host -Object "[Error] Unable to determine if the account '$env:Username' is running this script in an elevated session."
        exit 1
    }

    if (!$IsElevated) {
        Write-Host -Object "[Error] The user '$env:USERNAME' is not running this script in an elevated session. Please run this script as System or in an elevated session."
        exit 1
    }

    try { $IsSystem = Test-IsSystem -ErrorAction Stop }
    catch {
        Write-Host -Object "[Error] $($_.Exception.Message)"
        Write-Host -Object "[Error] Unable to determine if the account '$env:Username' is running this script as the System account."
        exit 1
    }

    if (-not $IsSystem) {
        Write-Host -Object "[Error] Please run this script as the SYSTEM account."
        exit 1
    }

    #region Validate Dell system and create destination folder
    try { $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop }
    catch {
        Write-Host -Object "[Error] Failed to retrieve computer system information."
        Write-Host -Object "[Error] $($_.Exception.Message)"
        exit 1
    }

    if ($ComputerSystem.Manufacturer -notmatch "^Dell") {
        Write-Host -Object "[Error] This script is intended to be run on Dell systems only. The current system manufacturer is '$($ComputerSystem.Manufacturer)'."
        exit 1
    }

    if (-not (Test-Path -Path $DestinationFolderPath)) {
        try {
            Write-Host -Object "[Info] The destination folder '$DestinationFolderPath' does not exist. Attempting to create the folder now."
            New-Item -Path $DestinationFolderPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Host -Object "[Info] Successfully created the directory at '$DestinationFolderPath'.`n"
        }
        catch {
            Write-Host -Object "[Warning] Failed to create the directory at '$DestinationFolderPath'."
            Write-Host -Object "[Warning] $($_.Exception.Message)"
            Write-Host -Object "[Info] Script will default to using the '$env:ProgramData\Dell\UpdateService' folder.`n"
            $DestinationFolderPath = "$env:ProgramData\Dell\UpdateService"
        }
    }
    #endregion

    #region Validate Dell model support
    try { $SupportedModels = Get-DellSupportedModels -DestinationFolder $DestinationFolderPath -ErrorAction Stop }
    catch {
        Write-Host -Object "[Error] Failed to retrieve the list of supported Dell models."
        Write-Host -Object "[Error] $($_.Exception.Message)"
        exit 1
    }

    $ComputerSKU = $ComputerSystem.SystemSKUNumber

   if ($ComputerSKU -notmatch "^[0-9A-F]{4}$") {
    Write-Host -Object "[Warning] '$ComputerSKU' does not appear to be a standard Dell SKU. Skipping SKU validation and proceeding."
}
elseif ($ComputerSKU -notin $SupportedModels.SKU) {
    Write-Host -Object "[Error] The computer's SKU of '$ComputerSKU' is not supported by Dell Command Update."
    exit 1
}
    #endregion

    Write-Host -Object "[Info] All output files will be saved to the folder: '$DestinationFolderPath'"
    if ($DestinationFolderPath -eq "$env:ProgramData\Dell\UpdateService") {
        Write-Host -Object "[Info] Note that by default, this folder is only accessible by the SYSTEM account.`n"
    }
    else {
        Write-Host -Object ""
    }

    #region Ensure Dell Client Management Service is running
    $DCUServiceName = "DellClientManagementService"
    try {
        $DCUService = Get-Service -Name $DCUServiceName -ErrorAction Stop
    }
    catch {
        # Service not found - log a warning but continue (may not be installed yet if InstallDCUAndDotNet8IfNeeded is set)
        Write-Host -Object "[Warning] The '$DCUServiceName' service was not found on this system. Dell Command Update may not be installed yet."
        Write-Host -Object "[Warning] $($_.Exception.Message)"
    }

    if ($DCUService) {
        # Fix startup type if not set to Automatic
        if ($DCUService.StartType -ne "Automatic") {
            Write-Host -Object "[Info] '$DCUServiceName' startup type is '$($DCUService.StartType)'. Setting to Automatic."
            try {
                Set-Service -Name $DCUServiceName -StartupType Automatic -ErrorAction Stop
                Write-Host -Object "[Info] Successfully set '$DCUServiceName' startup type to Automatic."
            }
            catch {
                Write-Host -Object "[Warning] Failed to set '$DCUServiceName' startup type to Automatic."
                Write-Host -Object "[Warning] $($_.Exception.Message)"
            }
        }

        # Start the service if it is not running
        if ($DCUService.Status -ne "Running") {
            Write-Host -Object "[Info] '$DCUServiceName' is not running (Status: $($DCUService.Status)). Attempting to start it."
            try {
                Start-Service -Name $DCUServiceName -ErrorAction Stop
                Write-Host -Object "[Info] Successfully started '$DCUServiceName'. Waiting 15 seconds for the service to initialize."
                Start-Sleep -Seconds 15

                # Verify the service is now running
                $DCUService = Get-Service -Name $DCUServiceName -ErrorAction Stop
                if ($DCUService.Status -ne "Running") {
                    Write-Host -Object "[Error] '$DCUServiceName' failed to reach Running status after start attempt. Current status: $($DCUService.Status)"
                    exit 1
                }
                Write-Host -Object "[Info] '$DCUServiceName' is now running."
            }
            catch {
                Write-Host -Object "[Error] Failed to start '$DCUServiceName'."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }
        }
        else {
            Write-Host -Object "[Info] '$DCUServiceName' is already running. Waiting 15 seconds for full initialization."
            Start-Sleep -Seconds 15
        }
    }
    #endregion

    #region Find/Install DCU CLI
    $DCUCLIPath = Get-Item -Path "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe", "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName -ErrorAction SilentlyContinue

    if (-not $DCUCLIPath -and -not $InstallDCUAndDotNet8IfNeeded) {
        Write-Host -Object "[Error] Dell Command Update is not installed on this system. Please use the 'Install Dell Command Update If Needed' parameter to install Dell Command Update."
        exit 1
    }
    elseif (-not $DCUCLIPath -and $InstallDCUAndDotNet8IfNeeded) {
        #region Check for/install .NET
        Write-Host -Object "[Info] Dell Command Update is not installed. Installing the latest version of Dell Command Update.`n"

        $RequiredDotNetVersion = [version]"8.0.8"
        $DotNetPath = "$env:ProgramFiles\dotnet\shared\Microsoft.WindowsDesktop.App\"

        if (Test-Path -Path $DotNetPath) {
            try { $VersionFolders = Get-ChildItem -Path $DotNetPath -Directory -ErrorAction Stop }
            catch {
                Write-Host -Object "[Error] Failed to retrieve .NET Desktop Runtime versions from path '$DotNetPath'."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }

            foreach ($Folder in $VersionFolders) {
                try { $ChildItems = Get-ChildItem -Path $Folder.FullName -ErrorAction Stop }
                catch {
                    Write-Host -Object "[Warning] Failed to retrieve child items from '$($Folder.FullName)'."
                    Write-Host -Object "[Warning] $($_.Exception.Message)"
                    continue
                }
                if (-not $ChildItems) { continue }
                $Version = $Folder.Name
                try { [version]$Version = $Version }
                catch { Write-Host -Object "[Warning] Cannot cast version '$Version': $($_.Exception.Message)" }
                if ($Version.Major -eq 8 -and $_.Version -ge $RequiredDotNetVersion) {
                    Write-Host -Object "[Info] Detected .NET Desktop Runtime version $Version at '$($Folder.FullName)'."
                    $IsDotNetInstalled = $True
                }
            }
        }

        if (-not $IsDotNetInstalled) {
            Write-Host -Object "[Info] Dell Command Update requires .NET Desktop Runtime 8 (64-bit) v8.0.8+, but it is not installed."
            Write-Host -Object "[Info] The latest version of .NET Desktop Runtime 8 (64-bit) will be installed.`n"

            try { $LatestDotNetInfo = Get-DotNet8LatestVersion -ErrorAction Stop }
            catch {
                Write-Host -Object "[Error] Failed to retrieve the latest .NET 8 version information."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }

            $DotNetDesktop64BitInstaller = $LatestDotNetInfo.DownloadURL
            $DotNetDesktop64BitVersion = $LatestDotNetInfo.Version
            $DotNetDesktop64BitInstallerFilePath = "$DestinationFolderPath\DotNetDesktop64BitInstaller.exe"

            try {
                Write-Host -Object "[Info] Downloading the .NET Desktop Runtime $DotNetDesktop64BitVersion installer to '$DotNetDesktop64BitInstallerFilePath'."
                Invoke-Download -URL "$DotNetDesktop64BitInstaller" -Path "$DotNetDesktop64BitInstallerFilePath" -UserAgent "Chrome" -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Host -Object "[Error] Failed to download the .NET Desktop Runtime $DotNetDesktop64BitVersion installer."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }

            try { $DownloadedDotNetSha512Hash = (Get-FileHash -Path "$DotNetDesktop64BitInstallerFilePath" -Algorithm SHA512 -ErrorAction Stop).Hash }
            catch {
                Write-Host -Object "[Error] Failed to compute the SHA512 hash of the .NET installer."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }

            $ExpectedDotNetSha512Hash = $LatestDotNetInfo.Hash
            if ($DownloadedDotNetSha512Hash -eq $ExpectedDotNetSha512Hash) {
                Write-Host -Object "[Info] Successfully verified the SHA512 hash of the .NET Desktop Runtime installer."
            }
            else {
                Write-Host -Object "[Error] SHA512 hash mismatch for .NET installer. Expected: $ExpectedDotNetSha512Hash | Actual: $DownloadedDotNetSha512Hash"
                Write-Host -Object "[Error] The installer may be corrupted or tampered with. Aborting installation."
                exit 1
            }

            try { $FileSignature = Get-AuthenticodeSignature -FilePath "$DotNetDesktop64BitInstallerFilePath" -ErrorAction Stop }
            catch {
                Write-Host -Object "[Error] $($_.Exception.Message)"
                Write-Host -Object "[Error] Failed to check file signature of '$DotNetDesktop64BitInstallerFilePath'."
                exit 1
            }

            if ($FileSignature.Status -ne "Valid") { Write-Host -Object "[Error] File signature is $($FileSignature.Status)."; exit 1 }
            if ($FileSignature.SignerCertificate.IssuerName.Name -notmatch "Microsoft Corporation") {
                Write-Host -Object "[Error] Unexpected issuer: '$($FileSignature.SignerCertificate.IssuerName.Name)'. Expected 'Microsoft Corporation'."
                exit 1
            }
            if ($FileSignature.SignerCertificate.Subject -notmatch "Microsoft Corporation") {
                Write-Host -Object "[Error] Unexpected subject: '$($FileSignature.SignerCertificate.Subject)'. Expected 'Microsoft Corporation'."
                exit 1
            }
            Write-Host "[Info] Successfully verified the digital signature of the .NET Desktop Runtime installer."

            try {
                Write-Host -Object "[Info] Starting the .NET Desktop Runtime $DotNetDesktop64BitVersion installer process."
                Start-Process -FilePath "$DotNetDesktop64BitInstallerFilePath" -ArgumentList "/install /quiet /norestart /log `"$DestinationFolderPath\DotNetDesktop64BitInstallerLog.log`"" -Wait -NoNewWindow -ErrorAction Stop
                if ($LASTEXITCODE -ne 0) {
                    Write-Host -Object "[Error] .NET installer exited with code $LASTEXITCODE. See log at '$DestinationFolderPath\DotNetDesktop64BitInstallerLog.log'."
                    exit 1
                }
                Write-Host -Object "[Info] Successfully installed .NET Desktop Runtime $DotNetDesktop64BitVersion.`n"
                $FilesToRemove = Get-ChildItem $DestinationFolderPath\DotNetDesktop64Bit* -ErrorAction SilentlyContinue
                foreach ($file in $filesToRemove) {
                    try { Remove-Item -Path $file.FullName -Force -ErrorAction Stop }
                    catch { Write-Host -Object "[Warning] Failed to delete '$($file.FullName)'. Please delete manually."; Write-Host -Object "[Warning] $($_.Exception.Message)" }
                }
            }
            catch {
                Write-Host -Object "[Error] Failed to start the .NET installer."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }
        }
        else {
            Write-Host -Object "[Info] .NET Desktop Runtime 8.0.8 or higher is already installed.`n"
        }
        #endregion

        #region Find/install DCU
        try {
            $LatestDellCommandUpdate = Get-DellAvailableUpdates -SystemSKU $ComputerSKU -DestinationFolder $DestinationFolderPath -Method "CatalogDownload" -Latest -ErrorAction Stop | Where-Object { $_.Name -match "Command.+Windows Universal" }
        }
        catch {
            Write-Host -Object "[Warning] Failed to retrieve Dell Command Update download URL from SKU '$ComputerSKU' catalog."
            Write-Host -Object "[Warning] $($_.Exception.Message)"
            Write-Host -Object "[Warning] Will attempt to find the latest version by scanning other Dell catalogs.`n"
            $PrintedDCUDownloadURLWarning = $True
        }

        $DellCommandUpdateDownloadURL = $LatestDellCommandUpdate.DownloadURL
        $ExpectedDCUSha256Hash = $LatestDellCommandUpdate.DownloadHashSha256
        $ExpectedDCUSha1Hash = $LatestDellCommandUpdate.DownloadHashSha1
        $ExpectedDCUMd5Hash = $LatestDellCommandUpdate.DownloadHashMD5
        $DellCommandUpdateVersion = $LatestDellCommandUpdate.VendorVersion

        if ([string]::IsNullOrWhiteSpace($DellCommandUpdateDownloadURL)) {
            if (-not $PrintedDCUDownloadURLWarning) {
                Write-Host -Object "[Warning] Dell Command Update was not found in the SKU '$ComputerSKU' catalog."
                Write-Host -Object "[Warning] Scanning other Dell catalogs to find the latest available version.`n"
            }
            try {
                $FallbackDCU = Get-LatestDCUFromCatalog -DestinationFolder $DestinationFolderPath -ErrorAction Stop
                $DellCommandUpdateDownloadURL = $FallbackDCU.DownloadURL
                $ExpectedDCUSha256Hash        = $FallbackDCU.DownloadHashSha256
                $ExpectedDCUSha1Hash          = $FallbackDCU.DownloadHashSha1
                $ExpectedDCUMd5Hash           = $FallbackDCU.DownloadHashMD5
                $DellCommandUpdateVersion     = $FallbackDCU.VendorVersion
            }
            catch {
                Write-Host -Object "[Error] Failed to find Dell Command Update via catalog scan."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }
        }

        $DellCommandUpdateInstallerFilePath = "$DestinationFolderPath\DellCommandUpdateInstaller.exe"

        try {
            Write-Host -Object "[Info] Downloading Dell Command Update version $DellCommandUpdateVersion to '$DellCommandUpdateInstallerFilePath'."
            Invoke-Download -URL "$DellCommandUpdateDownloadURL" -Path "$DellCommandUpdateInstallerFilePath" -UserAgent "Chrome" -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host -Object "[Error] Failed to download Dell Command Update."
            Write-Host -Object "$($_.Exception.Message)"
            exit 1
        }

        if ($ExpectedDCUSha256Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedDCUSha256Hash)) {
            $HashAlgorithmToCheck = "SHA256"; $ExpectedDCUHash = $ExpectedDCUSha256Hash
        }
        elseif ($ExpectedDCUSha1Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedDCUSha1Hash)) {
            $HashAlgorithmToCheck = "SHA1"; $ExpectedDCUHash = $ExpectedDCUSha1Hash
        }
        elseif ($ExpectedDCUMd5Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedDCUMd5Hash)) {
            $HashAlgorithmToCheck = "MD5"; $ExpectedDCUHash = $ExpectedDCUMd5Hash
        }
        else {
            Write-Host -Object "[Error] No valid hash found to verify the DCU installer. DCU cannot be installed."
            try { Remove-Item -Path "$DellCommandUpdateInstallerFilePath" -Force -ErrorAction Stop }
            catch { Write-Host -Object "[Warning] Failed to delete '$DellCommandUpdateInstallerFilePath'."; Write-Host -Object "[Warning] $($_.Exception.Message)" }
            exit 1
        }

        try { $DownloadedDCUHash = (Get-FileHash -Path "$DellCommandUpdateInstallerFilePath" -Algorithm $HashAlgorithmToCheck -ErrorAction Stop).Hash }
        catch {
            Write-Host -Object "[Error] Failed to compute $HashAlgorithmToCheck hash of DCU installer."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            exit 1
        }

        if ($DownloadedDCUHash -eq $ExpectedDCUHash) {
            Write-Host -Object "[Info] Successfully verified the $HashAlgorithmToCheck hash of the Dell Command Update installer."
        }
        else {
            Write-Host -Object "[Error] $HashAlgorithmToCheck hash mismatch for DCU installer. Expected: $ExpectedDCUHash | Actual: $DownloadedDCUHash"
            Write-Host -Object "[Error] The installer may be corrupted or tampered with. Aborting installation."
            try { Remove-Item -Path "$DellCommandUpdateInstallerFilePath" -Force -ErrorAction Stop }
            catch { Write-Host -Object "[Warning] Failed to delete '$DellCommandUpdateInstallerFilePath'."; Write-Host -Object "[Warning] $($_.Exception.Message)" }
            exit 1
        }

        try { $FileSignature = Get-AuthenticodeSignature -FilePath "$DellCommandUpdateInstallerFilePath" -ErrorAction Stop }
        catch {
            Write-Host -Object "[Error] $($_.Exception.Message)"
            Write-Host -Object "[Error] Failed to check file signature of '$DellCommandUpdateInstallerFilePath'."
            exit 1
        }

        if ($FileSignature.Status -ne "Valid") { Write-Host -Object "[Error] DCU installer signature is $($FileSignature.Status)."; exit 1 }
        if ($FileSignature.SignerCertificate.IssuerName.Name -notmatch "DigiCert, Inc.") {
            Write-Host -Object "[Error] Unexpected issuer: '$($FileSignature.SignerCertificate.IssuerName.Name)'. Expected 'DigiCert, Inc.'."
            exit 1
        }
        if ($FileSignature.SignerCertificate.Subject -notmatch "Dell Technologies Inc.") {
            Write-Host -Object "[Error] Unexpected subject: '$($FileSignature.SignerCertificate.Subject)'. Expected 'Dell Technologies Inc.'."
            exit 1
        }
        Write-Host "[Info] Successfully verified the digital signature of the Dell Command Update installer."

        try {
            Write-Host -Object "[Info] Starting the Dell Command Update installer process."
            $DCUInstallerProcess = Start-Process -FilePath "$DellCommandUpdateInstallerFilePath" -ArgumentList "/s /l=`"$DestinationFolderPath\DellCommandUpdateInstallerLog.log`"" -Wait -NoNewWindow -PassThru
        }
        catch {
            Write-Host -Object "[Error] Failed to start the Dell Command Update installer."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            exit 1
        }

        if ($DCUInstallerProcess.ExitCode -ne 0 -and $DCUInstallerProcess.ExitCode -ne 2) {
            Write-Host -Object "[Error] DCU installer exited with code $($DCUInstallerProcess.ExitCode). See log at '$DestinationFolderPath\DellCommandUpdateInstallerLog.log'."
            exit 1
        }

        Write-Host -Object "[Info] Successfully installed Dell Command Update version $DellCommandUpdateVersion.`n"

        $FilesToRemove = Get-ChildItem "$DestinationFolderPath\DellCommandUpdateInstaller*" -ErrorAction SilentlyContinue
        foreach ($file in $filesToRemove) {
            try { Remove-Item -Path $file.FullName -Force -ErrorAction Stop }
            catch { Write-Host -Object "[Warning] Failed to delete '$($file.FullName)'. Please delete manually."; Write-Host -Object "[Warning] $($_.Exception.Message)" }
        }
        #endregion

        $DCUCLIPath = Get-Item -Path "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe", "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName -ErrorAction SilentlyContinue

        if (-not $DCUCLIPath) {
            Write-Host -Object "[Error] 'dcu-cli.exe' still cannot be found after install. Please verify that Dell Command Update installed correctly."
            exit 1
        }
    }
    #endregion

    #region Scan for updates
    $UpdatesList = New-Object System.Collections.Generic.List[PSObject]

    try {
        Write-Host -Object "[Info] Scanning for available updates."
        Get-DellAvailableUpdates -Method "CLI" -DestinationFolder $DestinationFolderPath -ErrorAction Stop | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) { $UpdatesList.Add($_) }
        }
    }
    catch {
        Write-Host -Object "[Error] Failed to retrieve the list of available updates using dcu-cli.exe. The log file at '$DestinationFolderPath\DCUScan.log' may have more information."
        Write-Host -Object "[Error] $($_.Exception.Message)"
        exit 1
    }

    $InitialAvailableUpdatesCount = ($UpdatesList | Measure-Object).Count
    Write-Host -Object "[Info] Found $InitialAvailableUpdatesCount available updates for this system."

    if ($InitialAvailableUpdatesCount -gt 0) {
        Write-Host ""
        ($UpdatesList | Select-Object -Property PackageID, Name, Type, Category, Version, ReleaseDate, Severity, Status | Format-List | Out-String).Trim() | Write-Host
    }
    #endregion

    #region Install updates
    if ($InitialAvailableUpdatesCount -gt 0 -and ($InstallAllUpdates -or $ValidatedPackageIDs -or $InstallUpdatesByCategory -or $InstallUpdatesBySeverity -or $InstallUpdatesByType)) {
        Write-Host ""

        $UpdatesToInstall = $UpdatesList.PSObject.Copy()

        #region Filter updates to install
        if ($ValidatedPackageIDs) {
            $ValidatedPackageIDs | Where-Object { $_ -notin $UpdatesToInstall.PackageID } | ForEach-Object {
                Write-Host -Object "[Warning] Package ID '$_' not found in available updates. It will not be installed."
                $InvalidPackageIDs.Add($_); $AddNewLine = $True
            }
            $UpdatesToInstall = $UpdatesToInstall | Where-Object { $_.PackageID -in $ValidatedPackageIDs }
            if ($AddNewLine) { Write-Host "" }
        }
        if (-not $ValidatedPackageIDs -and $InstallUpdatesByType)     { $UpdatesToInstall = $UpdatesToInstall | Where-Object { $_.Type -eq $InstallUpdatesByType } }
        if (-not $ValidatedPackageIDs -and $InstallUpdatesByCategory)  { $UpdatesToInstall = $UpdatesToInstall | Where-Object { $_.Category -eq $InstallUpdatesByCategory } }
        if (-not $ValidatedPackageIDs -and $InstallUpdatesBySeverity)  { $UpdatesToInstall = $UpdatesToInstall | Where-Object { $_.Severity -match $InstallUpdatesBySeverity } }
        #endregion

        if (-not $UpdatesToInstall) {
            Write-Host -Object "[Error] No updates found that match the specified criteria. No updates will be installed.`n"
            $ExitCode = 1
        }
        else {
            $SuccessfulUpdates   = New-Object System.Collections.Generic.List[string]
            $RebootRequiredUpdates = New-Object System.Collections.Generic.List[string]
            $FailedUpdates       = New-Object System.Collections.Generic.List[string]
            $RebootRequired      = $false

            Write-Host -Object "[Info] The following updates will be installed: $($UpdatesToInstall.Name -join ", ").`n"

            try { $UpdateCatalog = Get-DellAvailableUpdates -SystemSKU $ComputerSKU -DestinationFolder $DestinationFolderPath -Method "CatalogDownload" -ErrorAction Stop }
            catch {
                Write-Host -Object "[Error] Failed to retrieve the Dell updates catalog. No updates will be installed."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                $SkipUpdates = $true; $ExitCode = 1
            }

            #region Update install loop
            if (-not $SkipUpdates) {
                foreach ($Update in $UpdatesToInstall) {
                    $UpdateName            = $Update.Name
                    $PackageID             = $Update.PackageID
                    $ExpectedUpdateSha256Hash = ($UpdateCatalog | Where-Object { $_.PackageID -eq $PackageID }).DownloadHashSha256
                    $ExpectedUpdateSha1Hash   = ($UpdateCatalog | Where-Object { $_.PackageID -eq $PackageID }).DownloadHashSha1
                    $ExpectedUpdateMd5Hash    = ($UpdateCatalog | Where-Object { $_.PackageID -eq $PackageID }).DownloadHashMD5
                    $UpdatePath            = "$DestinationFolderPath\$PackageID.exe"
                    $LogPath               = "$DestinationFolderPath\${PackageID}_InstallLog.log"
                    $LogContent = $null; $UpdateExitCode = $null; $NameOfExitCode = $null; $Result = $null

                    Write-Host "[Info] Working on the '$UpdateName' update."

                    try { Invoke-Download -URL $Update.DownloadURL -Path $UpdatePath -UserAgent "Chrome" -Attempts 3 -Overwrite -Quiet -SkipSleep -ErrorAction Stop | Out-Null }
                    catch {
                        Write-Host -Object "[Error] Failed to download '$UpdateName': $($_.Exception.Message)"
                        $ExitCode = 1; continue
                    }

                    if ($ExpectedUpdateSha256Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedUpdateSha256Hash)) {
                        $HashAlgorithmToCheck = "SHA256"; $ExpectedUpdateHash = $ExpectedUpdateSha256Hash
                    }
                    elseif ($ExpectedUpdateSha1Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedUpdateSha1Hash)) {
                        $HashAlgorithmToCheck = "SHA1"; $ExpectedUpdateHash = $ExpectedUpdateSha1Hash
                    }
                    elseif ($ExpectedUpdateMd5Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedUpdateMd5Hash)) {
                        $HashAlgorithmToCheck = "MD5"; $ExpectedUpdateHash = $ExpectedUpdateMd5Hash
                    }
                    else {
                        Write-Host -Object "[Error] No valid hash for '$UpdateName'. The update will not be installed."
                        try { Remove-Item -Path $UpdatePath -Force -ErrorAction Stop } catch { Write-Host -Object "[Warning] Failed to delete '$UpdatePath': $($_.Exception.Message)" }
                        $FailedUpdates.Add($PackageID); $ExitCode = 1; continue
                    }

                    try { $DownloadedUpdateHash = (Get-FileHash -Path $UpdatePath -Algorithm $HashAlgorithmToCheck -ErrorAction Stop).Hash }
                    catch {
                        Write-Host -Object "[Error] Failed to compute $HashAlgorithmToCheck hash for '$UpdateName': $($_.Exception.Message)"
                        try { Remove-Item -Path $UpdatePath -Force -ErrorAction Stop } catch { Write-Host -Object "[Warning] Failed to delete '$UpdatePath': $($_.Exception.Message)" }
                        $FailedUpdates.Add($PackageID); $ExitCode = 1; continue
                    }

                    if ($ExpectedUpdateHash -ne $DownloadedUpdateHash) {
                        Write-Host -Object "[Error] Hash mismatch for '$UpdateName'. Expected: $ExpectedUpdateHash | Actual: $DownloadedUpdateHash"
                        Write-Host -Object "[Error] The installer may be corrupted. Aborting installation of this update."
                        try { Remove-Item -Path $UpdatePath -Force -ErrorAction Stop } catch { Write-Host -Object "[Warning] Failed to delete '$UpdatePath': $($_.Exception.Message)" }
                        $FailedUpdates.Add($PackageID); $ExitCode = 1; continue
                    }
                    else { Write-Host -Object "[Info] Successfully verified the update's $HashAlgorithmToCheck hash." }

                    try { $FileSignature = Get-AuthenticodeSignature -FilePath "$UpdatePath" -ErrorAction Stop }
                    catch {
                        Write-Host -Object "[Error] Failed to check file signature of '$UpdatePath': $($_.Exception.Message)"
                        try { Remove-Item -Path $UpdatePath -Force -ErrorAction Stop } catch { Write-Host -Object "[Warning] Failed to delete '$UpdatePath': $($_.Exception.Message)" }
                        $FailedUpdates.Add($PackageID); $ExitCode = 1; continue
                    }

                    if ($FileSignature.Status -ne "Valid") {
                        Write-Host -Object "[Error] File signature of '$UpdatePath' is $($FileSignature.Status). It will not be installed."
                        try { Remove-Item -Path $UpdatePath -Force -ErrorAction Stop } catch { Write-Host -Object "[Warning] Failed to delete '$UpdatePath': $($_.Exception.Message)" }
                        $FailedUpdates.Add($PackageID); $ExitCode = 1; continue
                    }

                    $ValidSignatures = @("O=Dell Inc.?", "O=Dell Technologies Inc.?", "O=Intel Corporation", "O=Dell USA L.P.")
                    $ValidSignaturesRegex = $ValidSignatures -join "|"

                    if ($FileSignature.SignerCertificate.Subject -notmatch "$ValidSignaturesRegex") {
                        Write-Host -Object "[Error] Invalid signature subject '$($FileSignature.SignerCertificate.Subject)' for '$UpdatePath'. Expected Dell or Intel."
                        try { Remove-Item -Path $UpdatePath -Force -ErrorAction Stop } catch { Write-Host -Object "[Warning] Failed to delete '$UpdatePath': $($_.Exception.Message)" }
                        $FailedUpdates.Add($PackageID); $ExitCode = 1; continue
                    }

                    Write-Host -Object "[Info] Successfully verified the update's digital signature."
                    Write-Host -Object "[Info] Installing the update."

                    try { Start-Process -FilePath $UpdatePath -ArgumentList "/s /l=`"$LogPath`"" -Wait -NoNewWindow -ErrorAction Stop }
                    catch {
                        Write-Host -Object "[Error] Failed to start installation for '$UpdateName': $($_.Exception.Message)"
                        $ExitCode = 1
                    }

                    if (Test-Path -Path $LogPath) {
                        try { $LogContent = (Get-Content -Path $LogPath -ErrorAction Stop | Where-Object { $_ } | Out-String).Trim() }
                        catch { Write-Host -Object "[Error] Failed to read log for '$UpdateName': $($_.Exception.Message)"; $ExitCode = 1 }
                    }
                    else { Write-Host -Object "[Error] Log file for '$UpdateName' not found at '$LogPath'."; $ExitCode = 1 }

                    if ($LogContent) {
                        $SuccessfulExitCodes        = @(0, 2)
                        $SuccessfulNamesOfExitCodes = @("SUCCESS", "REBOOT_REQUIRED") -join "|"
                        $SuccessfulResults          = @("SUCCESS", "REBOOT") -join "|"

                        switch -Regex ($Update.Type) {
                            "Firmware|BIOS" {
                                try {
                                    $UpdateExitCode     = ([regex]::Matches($LogContent, "Exit Code = (?<ExitCode>\d+)") | Select-Object -Last 1).Groups[1].Value
                                    $RebootRequiredFromLog = ([regex]::Matches($LogContent, "Reboot Required"))
                                }
                                catch { Write-Host -Object "[Error] Failed to parse log for '$UpdateName': $($_.Exception.Message)"; $ExitCode = 1 }

                                if ($UpdateExitCode -in $SuccessfulExitCodes) {
                                    Write-Host -Object "[Info] Successfully installed the update.`n"
                                    $SuccessfulUpdates.Add($PackageID)
                                    if (($RebootRequiredFromLog | Measure-Object).Count -gt 0) {
                                        Write-Host -Object "[Info] The update '$UpdateName' requires a reboot to complete.`n"
                                        $RebootRequired = $true
                                        if (-not $SuspendBitLockerAndRebootIfNeeded) { $RebootRequiredUpdates.Add($PackageID) }
                                    }
                                }
                                else {
                                    Write-Host -Object "[Error] Update failed. See log at '$LogPath'. Exit Code: $UpdateExitCode"
                                    $FailedUpdates.Add($PackageID); $ExitCode = 1
                                }
                            }
                            default {
                                try {
                                    $UpdateExitCode = ([regex]::Matches($LogContent, "Exit Code set to: (?<UpdateExitCode>\d+)") | Select-Object -Last 1).Groups[1].Value
                                    $NameOfExitCode = ([regex]::Matches($LogContent, "Name of Exit Code: (?<NameOfExitCode>[^\n\r]*)") | Select-Object -Last 1).Groups[1].Value
                                    $Result         = ([regex]::Matches($LogContent, "Result: (?<r>[^\n\r]*)") | Select-Object -Last 1).Groups[1].Value
                                }
                                catch { Write-Host -Object "[Error] Failed to parse log for '$UpdateName': $($_.Exception.Message)"; $ExitCode = 1 }

                                if ($UpdateExitCode -in $SuccessfulExitCodes -and $NameOfExitCode -match "$SuccessfulNamesOfExitCodes" -and $Result -match "$SuccessfulResults") {
                                    Write-Host -Object "[Info] Successfully installed the update.`n"
                                    $SuccessfulUpdates.Add($PackageID)
                                    if ($NameOfExitCode -match "REBOOT_REQUIRED" -or $Result -match "REBOOT") {
                                        Write-Host -Object "[Info] The update '$UpdateName' requires a reboot to complete.`n"
                                        $RebootRequired = $true
                                        if (-not $SuspendBitLockerAndRebootIfNeeded) { $RebootRequiredUpdates.Add($PackageID) }
                                    }
                                }
                                else {
                                    Write-Host -Object "[Error] Update failed. See log at '$LogPath'. Exit Code: $UpdateExitCode | Name: $NameOfExitCode | Result: $Result"
                                    $FailedUpdates.Add($PackageID); $ExitCode = 1
                                }
                            }
                        }

                        if ($PackageID -in $SuccessfulUpdates) {
                            try { Remove-Item -Path $LogPath -Force -ErrorAction Stop }
                            catch { Write-Host -Object "[Warning] Failed to delete log '$LogPath'. Please delete manually."; Write-Host -Object "[Warning] $($_.Exception.Message)" }
                        }
                    }

                    try { Remove-Item -Path $UpdatePath -Force -ErrorAction Stop }
                    catch { Write-Host -Object "[Warning] Failed to delete installer '$UpdatePath'. Please delete manually."; Write-Host -Object "[Warning] $($_.Exception.Message)" }
                }
            }

            Write-Host -Object "[Info] Finished installing updates.`n"
        }
        #endregion

        $UpdatesList | ForEach-Object {
            if ($_.PackageID -in $SuccessfulUpdates -and $_.PackageID -notin $RebootRequiredUpdates) { $_.Status = "Installed" }
            elseif ($_.PackageID -in $RebootRequiredUpdates) { $_.Status = "Installed: Pending Reboot" }
            elseif ($_.PackageID -in $FailedUpdates) { $_.Status = "Failed to install" }
        }

        $AvailableUpdatesCountAfterInstall  = ($UpdatesList | Where-Object { $_.Status -notmatch "^Installed" } | Measure-Object).Count
        $InstalledUpdatesCountAfterInstall  = ($UpdatesList | Where-Object { $_.Status -match "^Installed" } | Measure-Object).Count
        $FailedUpdatesCountAfterInstall     = ($UpdatesList | Where-Object { $_.Status -eq "Failed to install" } | Measure-Object).Count

        Write-Host -Object "[Info] $InstalledUpdatesCountAfterInstall update(s) installed successfully. $FailedUpdatesCountAfterInstall update(s) failed. There are now $AvailableUpdatesCountAfterInstall available update(s).`n"

        if ($InstalledUpdatesCountAfterInstall -gt 0) {
            Write-Host -Object "[Info] These updates were installed successfully:"
            ($UpdatesList | Where-Object { $_.PackageID -in $SuccessfulUpdates } | Select-Object -ExpandProperty Name | ForEach-Object { "- $_" } | Out-String).Trim() | Write-Host
        }

        if ($FailedUpdatesCountAfterInstall -gt 0) {
            Write-Host -Object "`n[Error] These updates failed to install:"
            ($UpdatesList | Where-Object { $_.PackageID -in $FailedUpdates } | Select-Object -ExpandProperty Name | ForEach-Object { "- $_" } | Out-String).Trim() | Write-Host
        }
    }
    #endregion

    if ($InvalidPackageIDs -and ($MultilineCustomFieldName -or $WysiwygCustomFieldName)) {
        foreach ($PackageID in $InvalidPackageIDs) {
            $UpdatesList.Add([PSCustomObject]@{
                PackageID = $PackageID; Name = "Invalid Package ID"; Type = "N/A"; Category = "N/A"
                Version = "N/A"; ReleaseDate = "N/A"; DownloadURL = "N/A"; Severity = "N/A"; Status = "Not installed"
            })
        }
    }

    #region Set custom fields
    if ($WYSIWYGCustomFieldName) {
        if ($UpdatesList) {
            $HtmlTable = $UpdatesList | Select-Object -Property PackageID, Name, Type, Category, Version, ReleaseDate, Severity, Status | ConvertTo-Html -Fragment
            $HtmlTable = $HtmlTable -replace "<th>(\w+)</th>", '<th><b>$1</b></th>'
            $HtmlTable = $HtmlTable | ForEach-Object { if ($_ -match "Urgent") { $_ -replace "<tr>", "<tr class='danger'>" } else { $_ } }
            $HtmlTable = "<div class='card flex-grow-1'><div class='card-title-box'><div class='card-title'><i class='fa-solid fa-circle-up'></i>&nbsp;&nbsp;Available Dell Updates</div></div><div class='card-body' style='white-space: nowrap;'>$HtmlTable</div></div>"
        }
        else { $HtmlTable = "<p>Dell Command Update found no available updates as of $(Get-Date -Format G).</p>" }

        try {
            Write-Host -Object "`n[Info] Attempting to set the WYSIWYG custom field '$WYSIWYGCustomFieldName'."
            Set-NinjaProperty -Name $WYSIWYGCustomFieldName -Value $htmlTable -ErrorAction Stop
            Write-Host -Object "[Info] Successfully set the WYSIWYG custom field '$WYSIWYGCustomFieldName'."
        }
        catch {
            Write-Host -Object "[Error] Failed to set the WYSIWYG custom field '$WYSIWYGCustomFieldName'."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            $ExitCode = 1
        }
    }

    if ($MultilineCustomFieldName) {
        if ($UpdatesList) {
            $MultilineText = New-Object System.Collections.Generic.List[string]
            $MultilineText.Add(($UpdatesList | Where-Object { $_.Name -ne "Invalid Package ID" } | Select-Object -Property PackageID, Name, Type, Category, Version, ReleaseDate, Severity, Status | Format-List | Out-String).Trim())
            if ($InvalidPackageIDs) {
                $MultilineText.Add("`n`n")
                $MultilineText.Add(($UpdatesList | Where-Object { $_.Name -eq "Invalid Package ID" } | Select-Object -Property PackageID, Name, Status | Format-List | Out-String).Trim())
            }
        }
        else { $MultilineText = "Dell Command Update found no available updates as of $(Get-Date -Format G)." }

        try {
            Write-Host -Object "`n[Info] Attempting to set the multiline custom field '$MultilineCustomFieldName'."
            Set-NinjaProperty -Name $MultilineCustomFieldName -Value $MultilineText -ErrorAction Stop
            Write-Host -Object "[Info] Successfully set the multiline custom field '$MultilineCustomFieldName'."
        }
        catch {
            Write-Host -Object "[Error] Failed to set the multiline custom field '$MultilineCustomFieldName'."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            $ExitCode = 1
        }
    }
    #endregion

    #region Reboot if needed
    if ($RebootRequired -and $SuspendBitLockerAndRebootIfNeeded) {
        Write-Host ""

        try { $BitLockerStatus = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop }
        catch {
            Write-Host -Object "[Warning] Failed to retrieve BitLocker status."
            Write-Host -Object "[Warning] $($_.Exception.Message)"
            Write-Host -Object "[Warning] Proceeding without suspending BitLocker protection."
        }

        if ($BitLockerStatus.VolumeStatus -eq "FullyEncrypted" -and $BitLockerStatus.ProtectionStatus -eq "On") {
            Write-Host -Object "[Info] BitLocker is enabled. Attempting to suspend BitLocker protection on '$env:SystemDrive' for 1 reboot."
            try {
                Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop | Out-Null
                Write-Host -Object "[Info] Successfully suspended BitLocker. It will re-enable after the reboot."
            }
            catch {
                Write-Host -Object "[Error] Failed to suspend BitLocker on '$env:SystemDrive'."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                $ExitCode = 1
            }
            Write-Host ""
        }
        elseif ($BitLockerStatus.ProtectionStatus -eq "Off") {
            Write-Host -Object "[Info] BitLocker is already suspended."
            Write-Host ""
        }

        try { $RebootTime = (Get-Date).AddSeconds(60) }
        catch {
            Write-Host -Object "[Error] $($_.Exception.Message)"
            Write-Host -Object "[Error] Failed to calculate reboot time."
            $ExitCode = 1
        }

        Write-Host -Object "[Info] Scheduling reboot for $($RebootTime.ToShortDateString()) $($RebootTime.ToShortTimeString())."

        try {
            Start-Process -FilePath "$env:WINDIR\System32\shutdown.exe" -ArgumentList @("/r", "/t 60") -NoNewWindow -Wait -ErrorAction Stop
        }
        catch {
            Write-Host -Object "[Error] $($_.Exception.Message)"
            Write-Host -Object "[Error] Failed to schedule the reboot."
            exit 1
        }
    }

    if ($RebootRequired -and -not $SuspendBitLockerAndRebootIfNeeded) {
        Write-Host -Object "`n[Warning] A reboot is required to complete some updates, but 'Suspend BitLocker and Reboot If Needed' was not selected. Please reboot manually."
    }

    exit $ExitCode
}
end {
    
    
    
}
