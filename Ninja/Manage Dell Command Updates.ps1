#Requires -Version 5.1

<#
===============================================================================
SCRIPT:      Manage Dell Command Updates.ps1
AUTHOR:      Chad Mark
PLATFORM:    NinjaRMM
REPOSITORY:  https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/Manage%20Dell%20Command%20Updates.ps1
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

    # Check if the operating system build version is less than 10240 (Windows 10 minimum requirement)
    if ([System.Environment]::OSVersion.Version.Build -lt 10240) {
        Write-Host -Object "[Warning] The minimum OS version supported by this script is Windows 10 (10240)."
        Write-Host -Object "[Warning] OS build '$([System.Environment]::OSVersion.Version.Build)' detected. This could lead to errors or unexpected results.`n"
    }

    # Import script variables
    if ($env:DestinationFolderPath) { $DestinationFolderPath = $env:DestinationFolderPath }
    if ($env:SortUpdatesBy) { $SortUpdatesBy = $env:SortUpdatesBy }
    if ($env:WysiwygCustomFieldName) { $WysiwygCustomFieldName = $env:WysiwygCustomFieldName }
    if ($env:MultilineCustomFieldName) { $MultilineCustomFieldName = $env:MultilineCustomFieldName }
    if ($env:InstallUpdatesByPackageID) { $InstallUpdatesByPackageID = $env:InstallUpdatesByPackageID }
    if ($env:InstallUpdatesByCategory) { $InstallUpdatesByCategory = $env:InstallUpdatesByCategory }
    if ($env:InstallUpdatesBySeverity) { $InstallUpdatesBySeverity = $env:InstallUpdatesBySeverity }
    if ($env:InstallUpdatesByType) { $InstallUpdatesByType = $env:InstallUpdatesByType }

    # Validate the destination folder path
    if ($DestinationFolderPath) {
        $DestinationFolderPath = $DestinationFolderPath.Trim()

        # Error if the destination folder path is only whitespace
        if ([string]::IsNullOrWhiteSpace($DestinationFolderPath)) {
            Write-Host -Object "[Error] The 'Destination Folder Path' parameter contains only spaces. Please provide a valid folder path or leave it blank to use the default of '$env:ProgramData\Dell\CommandUpdate_Ninja'."
            exit 1
        }

        # Error if the destination folder path contains invalid characters or reserved characters after the drive letter
        if ($DestinationFolderPath -match '[/*?"<>|]' -or $DestinationFolderPath.SubString(3) -match "[:]") {
            Write-Host -Object "[Error] The 'Destination Folder Path' of '$DestinationFolderPath' contains one of the following invalid characters: '/*?`"<>|:'"
            exit 1
        }

        # Error if the destination folder path does not start with a drive letter and colon
        if ($DestinationFolderPath -notmatch "^[a-zA-Z]:\\") {
            Write-Host -Object "[Error] The 'Destination Folder Path' of '$DestinationFolderPath' is not valid. Please provide a full folder path starting with a drive letter, for example: C:\Folder\Subfolder."
            exit 1
        }

        # Define a list of forbidden folder paths per the Dell Command Update CLI documentation
        $ForbiddenFolderPaths = @($env:WinDir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:SystemDrive\Users\Public", $env:ProgramData, "$env:ProgramData\UpdateService\Clients")

        # Loop through each forbidden folder path and error if the destination folder path starts with it
        foreach ($ForbiddenFolderPath in $ForbiddenFolderPaths) {
            # Define the regex to match the forbidden folder path at the start of the destination folder path
            $ForbiddenFolderRegex = "^$([regex]::Escape($ForbiddenFolderPath))($|\\)"

            # The only exception is if the path is under "ProgramData\Dell"
            if ($DestinationFolderPath -match $ForbiddenFolderRegex -and $DestinationFolderPath -notmatch "^$([regex]::Escape($env:ProgramData))\\Dell($|\\)") {
                Write-Host -Object "[Error] The 'Destination Folder Path' of '$DestinationFolderPath' is not allowed. Please choose a different folder path."
                exit 1
            }
        }

        # Remove the trailing backslash if it exists
        if ($DestinationFolderPath -match "\\$") {
            $DestinationFolderPath = $DestinationFolderPath.TrimEnd("\")
        }
    }
    else {
        # If no destination folder path is provided, use the default path of "$env:ProgramData\Dell\UpdateService"
        $DestinationFolderPath = "$env:ProgramData\Dell\UpdateService"
    }

    # Validate the 'Sort Updates By' parameter
    if ($SortUpdatesBy -notin @("Name", "Type", "Category", "ReleaseDate", "Severity")) {
        Write-Host -Object "[Error] The 'Sort Updates By' value of '$SortUpdatesBy' is invalid. It must be one of the following values: Name, Type, Category, ReleaseDate, Severity."
        exit 1
    }

    # Validate the WYSIWYG custom field name if provided
    if ($WysiwygCustomFieldName) {
        # Trim the field name to remove leading and trailing whitespace
        $WysiwygCustomFieldName = $WysiwygCustomFieldName.Trim()

        # Validate that the field is not just whitespace
        if ([string]::IsNullOrWhiteSpace($WysiwygCustomFieldName)) {
            Write-Host -Object "[Error] The 'WYSIWYG Custom Field Name' parameter contains only spaces. Please provide a valid field name or leave it blank."
            exit 1
        }

        # Validate that the field name contains only alphanumeric characters
        if ($WysiwygCustomFieldName -match "[^0-9A-Z]") {
            Write-Host -Object "[Error] The 'WYSIWYG Custom Field Name' of '$WysiwygCustomFieldName' contains invalid characters."
            Write-Host -Object "[Error] Please provide a valid WYSIWYG custom field name to save the results, or leave it blank."
            Write-Host -Object "[Error] https://ninjarmm.zendesk.com/hc/en-us/articles/360060920631-Custom-Field-Setup"
            exit 1
        }
    }

    # Validate the Multiline custom field name if provided
    if ($MultilineCustomFieldName) {
        # Trim the field name to remove leading and trailing whitespace
        $MultilineCustomFieldName = $MultilineCustomFieldName.Trim()

        # Validate that the field is not just whitespace
        if ([string]::IsNullOrWhiteSpace($MultilineCustomFieldName)) {
            Write-Host -Object "[Error] The 'Multiline Custom Field Name' parameter contains only spaces. Please provide a valid field name or leave it blank."
            exit 1
        }

        # Validate that the field name contains only alphanumeric characters
        if ($MultilineCustomFieldName -match "[^0-9A-Z]") {
            Write-Host -Object "[Error] The 'Multiline Custom Field Name' of '$MultilineCustomFieldName' contains invalid characters."
            Write-Host -Object "[Error] Please provide a valid Multiline custom field name to save the results, or leave it blank."
            Write-Host -Object "[Error] https://ninjarmm.zendesk.com/hc/en-us/articles/360060920631-Custom-Field-Setup"
            exit 1
        }
    }

    # If 'Install All Updates' is used with any other 'Install' parameter, ignore the others and warn the user
    if ($InstallAllUpdates -and ($InstallUpdatesByPackageID -or $InstallUpdatesByCategory -or $InstallUpdatesBySeverity -or $InstallUpdatesByType)) {
        Write-Host -Object "[Warning] Only the 'Install All Updates' parameter will be used. All other 'Install' parameters will be ignored."
        $InstallUpdatesByPackageID = $null
        $InstallUpdatesByCategory = $null
        $InstallUpdatesBySeverity = $null
        $InstallUpdatesByType = $null
    }

    # If 'Install Updates By Package ID' is used with any other 'Install' parameter, ignore the others and warn the user
    if ($InstallUpdatesByPackageID -and ($InstallUpdatesByCategory -or $InstallUpdatesBySeverity -or $InstallUpdatesByType)) {
        Write-Host -Object "[Warning] Only the 'Install Updates By Package ID' parameter will be used. All other 'Install' parameters will be ignored."
        $InstallUpdatesByCategory = $null
        $InstallUpdatesBySeverity = $null
        $InstallUpdatesByType = $null
    }

    # Validate the package IDs if provided
    if ($InstallUpdatesByPackageID) {
        $InstallUpdatesByPackageID = $InstallUpdatesByPackageID.Trim()

        # Error if the package IDs are only whitespace
        if ([string]::IsNullOrWhiteSpace($InstallUpdatesByPackageID)) {
            Write-Host -Object "[Error] The 'Package IDs to Install' parameter contains only spaces. Please provide a comma-separated list of Package IDs or leave it blank."
            exit 1
        }

        # Split the package IDs by commas
        $PackageIDsToParse = $InstallUpdatesByPackageID -split ","

        # Initialize a list of validated package IDs
        $ValidatedPackageIDs = New-Object System.Collections.Generic.List[string]

        # Initialize a list of invalid package IDs
        $InvalidPackageIDs = New-Object System.Collections.Generic.List[string]

        # Validate each package ID
        foreach ($PackageID in $PackageIDsToParse) {
            $PackageID = $PackageID.Trim()

            # Warn and skip if the package ID contains invalid characters
            if ($PackageID -match "[^0-9A-Z]") {
                Write-Host -Object "[Warning] The package ID '$PackageID' contains invalid characters. Only alphanumeric characters are allowed."
                $InvalidPackageIDs.Add($PackageID)
                $AddNewLine = $True
                continue
            }

            # Warn and skip if the package ID is not exactly 5 characters long
            if ($PackageID -notmatch "^[0-9A-Z]{5}$") {
                Write-Host -Object "[Warning] The package ID '$PackageID' is not valid. Package IDs must be exactly 5 alphanumeric characters."
                $InvalidPackageIDs.Add($PackageID)
                $AddNewLine = $True
                continue
            }

            # Add the validated package ID to the list
            $ValidatedPackageIDs.Add($PackageID)
        }

        # Add a new line if any warnings were printed
        if ($AddNewLine) {
            Write-Host ""
            $AddNewLine = $False
        }

        # Error if no valid package IDs were provided
        if (-not $ValidatedPackageIDs) {
            Write-Host -Object "[Error] No valid package IDs were provided. Please provide a comma-separated list of valid Package IDs or leave it blank."
            exit 1
        }
    }

    # Validate the updates category if provided
    if ($InstallUpdatesByCategory) {
        $InstallUpdatesByCategory = $InstallUpdatesByCategory.Trim()

        # Error if the category is only whitespace
        if ([string]::IsNullOrWhiteSpace($InstallUpdatesByCategory)) {
            Write-Host -Object "[Error] The 'Install Updates By Category' parameter contains only spaces. Please provide a valid category or leave it blank."
            exit 1
        }

        # Error if multiple categories are provided
        if ($InstallUpdatesByCategory -match "[,;]") {
            Write-Host -Object "[Error] The 'Install Updates By Category' parameter only accepts a single category value. Please provide a valid category or leave it blank."
            exit 1
        }
    }

    # Validate the update severity if provided
    if ($InstallUpdatesBySeverity) {
        $InstallUpdatesBySeverity = $InstallUpdatesBySeverity.Trim()

        # Error if the severity is only whitespace
        if ([string]::IsNullOrWhiteSpace($InstallUpdatesBySeverity)) {
            Write-Host -Object "[Error] The 'Install Updates By Severity' parameter contains only spaces. Please provide a valid severity (Recommended, Urgent, Optional) or leave it blank."
            exit 1
        }

        # Error if multiple severities are provided
        if ($InstallUpdatesBySeverity -match "[,;\s]") {
            Write-Host -Object "[Error] The 'Install Updates By Severity' parameter only accepts a single severity value. Please provide one of the valid severities (Recommended, Urgent, Optional) or leave it blank."
            exit 1
        }

        # Error if the severity is not one of the valid options
        if ($InstallUpdatesBySeverity -notin @("Recommended", "Urgent", "Optional")) {
            Write-Host -Object "[Error] '$InstallUpdatesBySeverity' is not a valid update severity. Please provide a valid severity (Recommended, Urgent, Optional) or leave it blank."
            exit 1
        }
    }

    # Verify the update type if provided
    if ($InstallUpdatesByType) {
        $InstallUpdatesByType = $InstallUpdatesByType.Trim()

        # Error if the type is only whitespace
        if ([string]::IsNullOrWhiteSpace($InstallUpdatesByType)) {
            Write-Host -Object "[Error] The 'Install Updates By Type' parameter contains only spaces. Please provide a valid type (BIOS, Firmware, Driver, Application) or leave it blank."
            exit 1
        }

        # Error if multiple types are provided
        if ($InstallUpdatesByType -match "[,;\s]") {
            Write-Host -Object "[Error] The 'Install Updates By Type' parameter only accepts a single type value. Please provide one of the valid types (BIOS, Firmware, Driver, Application) or leave it blank."
            exit 1
        }

        # Error if the type is not one of the valid options
        if ($InstallUpdatesByType -notin @("BIOS", "Firmware", "Driver", "Application")) {
            Write-Host -Object "[Error] '$InstallUpdatesByType' is not a valid update type. Please provide a valid type (BIOS, Firmware, Driver, Application) or leave it blank."
            exit 1
        }
    }

    #region Helper functions
    # Utility function for downloading files.
    function Invoke-Download {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $True)]
            [System.Uri]$URL,
            [Parameter(Mandatory = $True)]
            [String]$Path,
            [Parameter()]
            [int]$Attempts = 3,
            [Parameter()]
            [Switch]$SkipSleep,
            [Parameter()]
            [Switch]$Overwrite,
            [Parameter()]
            [ValidateSet("Chrome", "Edge", "Firefox", "Firefox ESR", "Safari", "InternetExplorer", "Opera")]
            [String]$UserAgent,
            [Parameter()]
            [Switch]$Quiet
        )

        # Determine the supported TLS versions and set the appropriate security protocol
        # Prefer Tls13 and Tls12 if both are available, otherwise just Tls12, or warn if unsupported.
        $SupportedTLSversions = [enum]::GetValues('Net.SecurityProtocolType')
        if ( ($SupportedTLSversions -contains 'Tls13') -and ($SupportedTLSversions -contains 'Tls12') ) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol::Tls13 -bor [System.Net.SecurityProtocolType]::Tls12
        } elseif ( $SupportedTLSversions -contains 'Tls12' ) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        } else {
            # Warn the user if TLS 1.2 and 1.3 are not supported, which may cause the download to fail
            Write-Host -Object "[Warning] TLS 1.2 and/or TLS 1.3 are not supported on this system. This download may fail!"
            if ($PSVersionTable.PSVersion.Major -lt 3) {
                Write-Host -Object "[Warning] PowerShell 2 / .NET 2.0 doesn't support TLS 1.2."
            }
        }

        # Trim whitespace from the URL and Path parameters.
        if ($Path) { $Path = $Path.Trim() }

        # Throw an error if no URL or Path was provided.
        if (!$URL) { throw [System.ArgumentNullException]::New("You must provide a URL.") }
        if (!$Path) { throw [System.ArgumentNullException]::New("You must provide a file path.") }

        # If the URL doesn't start with http or https, prepend https.
        if ($URL -notmatch "^http") {
            try {
                $URL = [System.Uri]"https://$URL"
            } catch {
                throw [System.UriFormatException]::New("[Error] The URL '$($URL.OriginalString)' is not valid. Please ensure it starts with http:// or https:// and is properly formatted.")
            }
            Write-Host -Object "[Warning] The URL given is missing http(s). The URL has been modified to the following: '$($URL.AbsoluteUri)'."
        } elseif (-not $Quiet) {
            # Display the URL being used for the download.
            Write-Host -Object "URL '$($URL.AbsoluteUri)' was given."
        }

        # Check if the path contains invalid characters or reserved characters after the drive letter.
        if ($Path -and ($Path -match '[/*?"<>|]' -or ($Path.Length -ge 2 -and $Path.Substring(2) -match "[:]"))) {
            throw [System.IO.InvalidDataException]::New("[Error] The file path specified '$Path' contains one of the following invalid characters: '/*?`"<>|:'")
        }

        # Check each folder in the path to ensure it isn't a reserved name (CON, PRN, AUX, etc.).
        $Path -split '\\' | ForEach-Object {
            $Folder = ($_).Trim()
            if ($Folder -match '^(CON|PRN|AUX|NUL)$' -or $Folder -match '^(LPT|COM)\d+$') {
                throw [System.IO.InvalidDataException]::New("[Error] An invalid folder name was given in '$Path'. The following folder names are reserved: CON, PRN, AUX, NUL, COM1-9, LPT1-9")
            }
        }

        # Temporarily disable progress reporting to speed up script performance
        $PreviousProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'

        # If no filename is included in the path (no extension), try to determine it from Content-Disposition.
        if (($Path | Split-Path -Leaf) -notmatch "[.]") {

            if (-not $Quiet) { Write-Host -Object "No filename provided in '$Path'. Checking the URL for a suitable filename." }

            $AbsolutePath = $URL.AbsolutePath

            # If the AbsolutePath is not blank or a slash, attempt to extract the filename from the OriginalString of the URL.
            if ($AbsolutePath -ne "/" -and $AbsolutePath -ne "") {
                $ProposedFilename = Split-Path $URL.OriginalString -Leaf
            }

            # Verify that the proposed filename doesn't contain invalid characters.
            if ($ProposedFilename -and $ProposedFilename -notmatch "[^A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]" -and $ProposedFilename -match "[.]") {
                $Filename = $ProposedFilename
            }

            # If running on older PowerShell versions without Invoke-WebRequest require a filename.
            if ($PSVersionTable.PSVersion.Major -lt 4) {
                # Restore the original progress preference setting
                $ProgressPreference = $PreviousProgressPreference

                throw [System.NotSupportedException]::New("You must provide a filename for systems not running PowerShell 4 or higher.")
            }

            if (!$Filename) {
                if (-not $Quiet) { Write-Host -Object "No filename was discovered in the URL. Attempting to discover the filename via the Content-Disposition header." }
                $Request = 1

                # Make multiple attempts (as defined by $Attempts) to retrieve the Content-Disposition header.
                while ($Request -le $Attempts) {
                    # If SkipSleep is not set, wait for a random time between 3 and 15 seconds before each attempt
                    if (!($SkipSleep)) {
                        $SleepTime = Get-Random -Minimum 3 -Maximum 15
                        if (-not $Quiet) { Write-Host -Object "Waiting for $SleepTime seconds." }
                        Start-Sleep -Seconds $SleepTime
                    }

                    if ($Request -ne 1 -and -not $Quiet) { Write-Host "" }
                    if (-not $Quiet) { Write-Host -Object "Attempt $Request" }

                    # Perform a HEAD request to get headers only.
                    # If the HEAD request fails, print a warning.
                    try {
                        $HeaderRequest = Invoke-WebRequest -Uri $URL -Method "HEAD" -MaximumRedirection 10 -UseBasicParsing -ErrorAction Stop
                    } catch {
                        Write-Host -Object "[Warning] $($_.Exception.Message)"
                        Write-Host -Object "[Warning] The header request failed."
                    }

                    # Check if the Content-Disposition header is present.
                    # If present, parse it to extract the filename.
                    if (!$HeaderRequest.Headers."Content-Disposition") {
                        Write-Host -Object "[Warning] The web server did not provide a Content-Disposition header."
                    } else {
                        $Content = [System.Net.Mime.ContentDisposition]::new($HeaderRequest.Headers."Content-Disposition")
                        $Filename = $Content.FileName
                    }

                    # If a filename was found, break out of the loop.
                    if ($Filename) {
                        $Request = $Attempts
                    }

                    $Request++
                }
            }

            # If a filename is still not found, throw an error.
            if ($Filename) {
                $Path = "$Path\$Filename"
            } else {
                # Restore the original progress preference setting
                $ProgressPreference = $PreviousProgressPreference

                throw [System.IO.FileNotFoundException]::New("Unable to find a suitable filename from the URL.")
            }
        }

        # If the file already exists at the specified path, restore the progress setting and throw an error.
        if ((Test-Path -Path $Path -ErrorAction SilentlyContinue) -and !$Overwrite) {
            # Restore the original progress preference setting
            $ProgressPreference = $PreviousProgressPreference

            throw [System.IO.IOException]::New("A file already exists at the path '$Path'.")
        }

        # Remove any extra slashes from the path.
        $Path = $Path -replace '\\+', '\'

        # Ensure that the destination folder exists, if not, try to create it.
        $DestinationFolder = $Path | Split-Path
        if (!(Test-Path -Path $DestinationFolder -ErrorAction SilentlyContinue)) {
            try {
                if (-not $Quiet) { Write-Host -Object "Attempting to create the folder '$DestinationFolder' as it does not exist." }
                New-Item -Path $DestinationFolder -ItemType "directory" -ErrorAction Stop | Out-Null
                if (-not $Quiet) { Write-Host -Object "Successfully created the folder." }
            } catch {
                # Restore the original progress preference setting
                $ProgressPreference = $PreviousProgressPreference

                throw $_
            }
        }

        # Determine the user agent string based on the provided UserAgent parameter
        if ($UserAgent) {
            $UserAgentString = switch ($UserAgent) {
                "Chrome" {
                    "Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) AppleWebKit/534.6 (KHTML, like Gecko) Chrome/7.0.500.0 Safari/534.6"
                }
                "Edge" {
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36 Edg/139.0.3405.86"
                }
                "Firefox" {
                    "Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) Gecko/20100401 Firefox/4.0"
                }
                "Firefox ESR" {
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"
                }
                "InternetExplorer" {
                    "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT; Windows NT 10.0; en-US)"
                }
                "Opera" {
                    "Opera/9.70 (Windows NT; Windows NT 10.0; en-US) Presto/2.2.1"
                }
                "Safari" {
                    "Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) AppleWebKit/533.16 (KHTML, like Gecko) Version/5.0 Safari/533.16"
                }
            }
        }

        if (-not $Quiet) { Write-Host -Object "Downloading the file..." }

        # Initialize the download attempt counter.
        $DownloadAttempt = 1
        while ($DownloadAttempt -le $Attempts) {
            # If SkipSleep is not set, wait for a random time between 3 and 15 seconds before each attempt
            if (!($SkipSleep)) {
                $SleepTime = Get-Random -Minimum 3 -Maximum 15
                if (-not $Quiet) { Write-Host -Object "Waiting for $SleepTime seconds." }
                Start-Sleep -Seconds $SleepTime
            }

            # Provide a visual break between attempts
            if ($DownloadAttempt -ne 1 -and -not $Quiet) { Write-Host "" }
            if (-not $Quiet) { Write-Host -Object "Download Attempt $DownloadAttempt" }

            try {
                if ($PSVersionTable.PSVersion.Major -lt 4) {
                    # For older versions of PowerShell, use WebClient to download the file
                    $WebClient = New-Object System.Net.WebClient

                    # Set the user agent if requested
                    if ($UserAgent) {
                        $WebClient.Headers.Add("User-Agent", $UserAgentString)
                    }

                    # Download the file
                    $WebClient.DownloadFile($URL, $Path)
                } else {
                    # For PowerShell 4.0 and above, use Invoke-WebRequest with specified arguments
                    $WebRequestArgs = @{
                        Uri                = $URL
                        OutFile            = $Path
                        MaximumRedirection = 10
                        UseBasicParsing    = $true
                    }

                    # Set the user agent if requested
                    if ($UserAgent) {
                        $WebRequestArgs.Add("UserAgent", $UserAgentString)
                    }

                    Invoke-WebRequest @WebRequestArgs
                }

                # Verify if the file was successfully downloaded
                $File = Test-Path -Path $Path -ErrorAction SilentlyContinue
            } catch {
                # Handle any errors that occur during the download attempt
                Write-Host -Object "[Warning] An error has occurred while downloading!"
                Write-Host -Object "[Warning] $($_.Exception.Message)"

                # If the file partially downloaded, delete it to avoid corruption
                if (Test-Path -Path $Path -ErrorAction SilentlyContinue) {
                    Remove-Item $Path -Force -Confirm:$false -ErrorAction SilentlyContinue
                }

                $File = $False
            }

            # If the file was successfully downloaded, exit the loop
            if ($File) {
                $DownloadAttempt = $Attempts
            } elseif ($DownloadAttempts -ne ($Attempts - 1)) {
                # Warn the user if the download attempt failed and there are remaining attempts
                Write-Host -Object "[Warning] File failed to download. Retrying...`n"
            }

            # Increment the attempt counter
            $DownloadAttempt++
        }

        # Restore the original progress preference setting
        $ProgressPreference = $PreviousProgressPreference

        # Final check: if the file still doesn't exist, report an error and exit
        if (!(Test-Path $Path)) {
            throw [System.IO.FileNotFoundException]::New("[Error] Failed to download file. Please verify the URL of '$URL'.")
        } else {
            # If the download succeeded, return the path to the downloaded file
            return $Path
        }
    }

    # Function to retrieve the list of supported Dell models from the Dell Command Update catalog
    function Get-DellSupportedModels {
        [CmdletBinding()]
        param (
            [Parameter()]
            [string]$DestinationFolder
        )

        # Error if no destination folder path is provided
        if ([string]::IsNullOrWhitespace($DestinationFolder)) {
            throw [System.ArgumentException]::New("A valid DestinationFolder is required to store the files this function downloads.")
        }

        # Define the paths for the downloaded cab file, the extracted XML file and the update catalog URL
        $SupportedModelsCabPath = "$DestinationFolder\CatalogIndexPC.cab"
        $SupportedModelsXmlPath = "$DestinationFolder\SupportedModels.xml"
        $CatalogURL = "https://downloads.dell.com/catalog/CatalogIndexPC.cab"

        # Download the supported models file
        try {
            Invoke-Download -URL $CatalogURL -Path $SupportedModelsCabPath -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null
        }
        catch {
            throw $_
        }

        # Attempt to expand the cab file to an XML file
        try {
            Invoke-LegacyConsoleTool -FilePath "expand" -ArgumentList "`"$SupportedModelsCabPath`" `"$SupportedModelsXmlPath`"" -ErrorAction Stop | Out-Null
        }
        catch {
            throw $_
        }

        # Error if the expand command failed
        if ($LASTEXITCODE -ne 0) {
            throw [System.Exception]::New("Unable to extract the SupportedModels.xml file from the downloaded CatalogIndexPC.cab file.")
        }

        # Error if the XML file does not exist
        if (-not (Test-Path $SupportedModelsXmlPath)) {
            throw [System.IO.FileNotFoundException]::New("The extracted SupportedModels.xml file was not found at the expected path of '$SupportedModelsXmlPath'.")
        }

        # Retrieve the content of the XML file
        try {
            $SupportedModelsXml = Get-Content -Path $SupportedModelsXmlPath -ErrorAction Stop
        }
        catch {
            throw [System.Exception]::New("Failed to read the SupportedModels.xml file.")
        }

        # Convert the XML file to an object so it can be parsed
        try {
            $SupportedModelsXml = [xml]$SupportedModelsXml
        }
        catch {
            throw [System.InvalidCastException]::New("Failed to parse the SupportedModels.xml file. The file at '$SupportedModelsXmlPath' is not valid XML.")
        }

        # Initialize a new object to hold the supported model information
        $SupportedModelsObject = New-Object System.Collections.Generic.List[PSObject]

        # Iterate through each model in the manifest and create a custom object for each
        foreach ($Model in $SupportedModelsXml.ManifestIndex.GroupManifest) {
            $ModelObject = [PSCustomObject]@{
                SKU     = $Model.SupportedSystems.Brand.Model.systemID
                Brand   = $Model.SupportedSystems.Brand.Display."#cdata-section"
                Model   = $Model.SupportedSystems.Brand.Model.Display."#cdata-section"
                URL     = $Model.ManifestInformation.path
                Version = $Model.ManifestInformation.version
            }

            # Add the model object to the list
            $SupportedModelsObject.Add($ModelObject)
        }

        # Return the list of supported models
        return $SupportedModelsObject
    }

    # Function to retrieve the list of available updates for a given Dell SKU, using either the Dell Command Update catalog or the Dell Command Update CLI
    function Get-DellAvailableUpdates {
        [CmdletBinding()]
        param (
            [Parameter()]
            [string]$SystemSKU,
            [Parameter()]
            [string]$Method,
            [Parameter()]
            [string]$DestinationFolder,
            [Parameter()]
            [switch]$Latest
        )

        # Error if no method is provided
        if ([string]::IsNullOrWhiteSpace($Method)) {
            throw [System.ArgumentException]::New("A method is required. Please provide either 'CatalogDownload' or 'CLI'.")
        }

        # Error if a valid method is not provided
        if ($Method -notin @("CatalogDownload", "CLI")) {
            throw [System.ArgumentException]::New("Invalid method '$Method' provided. Valid methods are 'CatalogDownload' and 'CLI'.")
        }

        # Error if no destination folder path is provided
        if ([string]::IsNullOrWhitespace($DestinationFolder)) {
            throw [System.ArgumentException]::New("A valid DestinationFolder is required to store the files this function downloads.")
        }

        if ($Method -eq "CatalogDownload") {
            if ([string]::IsNullOrWhiteSpace($SystemSKU)) {
                throw [System.ArgumentException]::New("A SystemSKU is required when using the CatalogDownload method.")
            }

            # If the SupportedModels variable does not exist, retrieve the list of supported Dell models from the Dell Command Update catalog
            if (-not $SupportedModels) {
                try {
                    $SupportedModels = Get-DellSupportedModels -DestinationFolder $DestinationFolder -ErrorAction Stop
                }
                catch {
                    throw $_
                }
            }

            # Retrieve the update catalog URL from the supported models list based on the given SKU
            $UpdateURL = ($SupportedModels | Where-Object { $_.SKU -eq $SystemSKU }).URL

            # Error if the URL does not exist for the given SKU
            if ([string]::IsNullOrWhiteSpace($UpdateURL)) {
                throw [System.Exception]::New("Could not find an update catalog for the model with SKU of '$SystemSKU'. This model may not be supported by Dell Command Update.")
            }

            # Define the paths for the downloaded cab and extracted XML file
            $UpdatesFromCatalogCabPath = "$DestinationFolder\CatalogIndexModel.cab"
            $UpdatesFromCatalogXMLPath = "$DestinationFolder\UpdatesFromCatalog.xml"

            # Download the available updates for the current model
            try {
                Invoke-Download -URL "https://downloads.dell.com/$UpdateURL" -Path $UpdatesFromCatalogCabPath -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null
            }
            catch {
                throw $_
            }

            # Extract the UpdatesFromCatalog.xml file from the downloaded cab
            try {
                Invoke-LegacyConsoleTool -FilePath "expand" -ArgumentList "`"$UpdatesFromCatalogCabPath`" `"$UpdatesFromCatalogXMLPath`"" -ErrorAction Stop | Out-Null
            }
            catch {
                throw [System.Exception]::New("Unable to extract the UpdatesFromCatalog.xml file for the model with SKU of '$ComputerSKU'.")
            }

            # Error if the expand command failed
            if ($LASTEXITCODE -ne 0) {
                throw [System.Exception]::New("Unable to extract the UpdatesFromCatalog.xml file for the model with SKU of '$ComputerSKU'.")
            }

            # Error if the XML file does not exist
            if (-not (Test-Path $UpdatesFromCatalogXMLPath)) {
                throw [System.IO.FileNotFoundException]::New("The extracted UpdatesFromCatalog.xml file for the model with SKU of '$ComputerSKU' was not found at the expected path of '$UpdatesFromCatalogXMLPath'.")
            }

            # Retrieve the content of the XML file
            try {
                $UpdatesFromCatalogXML = Get-Content -Path $UpdatesFromCatalogXMLPath -ErrorAction Stop
            }
            catch {
                throw [System.Exception]::New("Failed to read the UpdatesFromCatalog.xml file for the model with SKU of '$ComputerSKU'.")
            }

            # Convert the XML file to an object so it can be parsed
            try {
                $UpdatesFromCatalogXML = [xml]$UpdatesFromCatalogXML
            }
            catch {
                throw [System.InvalidCastException]::New("Failed to parse the UpdatesFromCatalog.xml file. The file at '$UpdatesFromCatalogXMLPath' is not valid XML.")
            }

            # Initialize a list to hold the available updates
            $AvailableUpdatesList = New-Object System.Collections.Generic.List[PSObject]

            $BaseUpdateURL = $UpdatesFromCatalogXML.Manifest.baseLocation

            # Parse the XML object to extract update information
            foreach ($Update in $UpdatesFromCatalogXML.Manifest.SoftwareComponent) {
                $UpdateObject = [PSCustomObject]@{
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
                }

                # Add the update object to the list
                $AvailableUpdatesList.Add($UpdateObject)
            }

            # If the Latest switch is specified, filter the list to only include the latest version of each update
            if ($Latest) {
                $AvailableUpdatesList = $AvailableUpdatesList | Group-Object Name | ForEach-Object { $_.Group | Sort-Object { [datetime]::Parse($_.ReleaseDate) } -Descending | Select-Object -First 1 }
            }
        }

        if ($Method -eq "CLI") {
            # If the Inventory.xml file exists from a previous scan, remove it to ensure a fresh inventory scan
            if (Test-Path "$env:ProgramData\Dell\UpdateService\Temp\Inventory.xml") {
                try {
                    Remove-Item -Path "$env:ProgramData\Dell\UpdateService\Temp\Inventory.xml" -Force -ErrorAction Stop
                }
                catch {
                    throw [System.Exception]::New("Unable to remove the existing Inventory.xml file at '$env:ProgramData\Dell\UpdateService\Temp\Inventory.xml'.`n$($_.Exception.Message)")
                }

                # Restart the service to ensure a fresh scan
                try {
                    Restart-Service -Name "DellClientManagementService" -Force -ErrorAction Stop | Out-Null
                }
                catch {
                    throw [System.Exception]::New("Unable to restart the Dell Client Management Service.`n$($_.Exception.Message)")
                }
            }

            # Define the paths for the scanned updates XML and log files
            # The XML file name cannot be changed as it is hardcoded in the DCU CLI
            $ScannedUpdatesXMLPath = "$DestinationFolder\DCUApplicableUpdates.xml"
            $ScannedUpdatesLogFilePath = "$DestinationFolder\DCUScan.log"

            # Run the scan command
            try {
                $DCUCLIArguments = "/scan -silent -report=`"$DestinationFolder`" -outputLog=`"$ScannedUpdatesLogFilePath`""
                Invoke-LegacyConsoleTool -FilePath $DCUCLIPath -ArgumentList $DCUCLIArguments -ErrorAction Stop | Out-Null
            }
            catch {
                throw $_
            }

            switch ($LASTEXITCODE) {
                0 {}
                5 { throw [System.Exception]::New("Unable to scan for updates because a reboot is required. Please reboot the device then run the script again.") }
                6 { throw [System.Exception]::New("Dell Command Update is already running. Please stop other instances of DCU then run the script again.") }
                107 { throw [System.Exception]::New("Dell Command Update rejected the command line arguments. This is likely due to an invalid destination folder.") }
                500 {} # No updates were found
                default { throw [System.Exception]::New("Dell Command Update scan exited with code $LASTEXITCODE.") }
            }

            # Error if the XML file does not exist
            if (-not (Test-Path $ScannedUpdatesXMLPath)) {
                throw [System.IO.FileNotFoundException]::New("The DCUApplicableUpdates.xml file was not found at the expected path of '$ScannedUpdatesXMLPath'.")
            }

            # Retrieve the content of the XML file
            try {
                $ScannedUpdatesXML = Get-Content -Path "$ScannedUpdatesXMLPath" -ErrorAction Stop
            }
            catch {
                throw [System.Exception]::New("Failed to read the available updates scan file at '$ScannedUpdatesXMLPath'.")
            }

            # Convert the XML file to an object so it can be parsed
            try {
                $ScannedUpdatesXML = [xml]$ScannedUpdatesXML
            }
            catch {
                throw [System.InvalidCastException]::New("Failed to parse the available updates scan file. The file at '$ScannedUpdatesXMLPath' is not valid XML.")
            }

            # Convert the XML file to an object so it can be parsed
            try {
                [xml]$ScannedUpdatesXML = Get-Content -Path "$ScannedUpdatesXMLPath" -ErrorAction Stop
            }
            catch {
                throw $_
            }

            # Initialize a list to hold the available updates
            $AvailableUpdatesList = New-Object System.Collections.Generic.List[PSObject]

            # Parse the XML object to extract update information
            foreach ($Update in $ScannedUpdatesXML.updates.update) {
                $UpdateObject = [PSCustomObject]@{
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
                }

                # Add the update object to the list
                $AvailableUpdatesList.Add($UpdateObject)
            }
        }

        # Sort the available updates list by the specified property
        switch ($SortUpdatesBy) {
            "Name" { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object Name }
            "Type" { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object Type, Name }
            "Category" { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object Category, Name }
            "ReleaseDate" { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object @{ Expression = { Get-Date $_.ReleaseDate }; Descending = $True }, Name }
            "Severity" { $AvailableUpdatesList = $AvailableUpdatesList | Sort-Object @{Expression = { if ($_.Severity -match "Urgent") { 1 } elseif ($_.Severity -eq "Recommended") { 2 } elseif ($_.Severity -eq "Optional") { 3 } } }, Name }
        }

        return $AvailableUpdatesList
    }

    function Invoke-LegacyConsoleTool {
        [CmdletBinding()]
        param(
            [Parameter()]
            [String]$FilePath,
            [Parameter()]
            [String[]]$ArgumentList,
            [Parameter()]
            [String]$WorkingDirectory,
            [Parameter()]
            [Int]$Timeout = 30,
            [Parameter()]
            [System.Text.Encoding]$Encoding
        )

        # Validate that the file path is not null or empty
        if ([String]::IsNullOrEmpty($FilePath) -or $FilePath -match "^\s+$") {
            throw (New-Object System.ArgumentNullException("You must provide a file path to the legacy tool you are trying to use."))
        }

        if ($WorkingDirectory) {
            # Validate that the working directory is not empty
            if ([String]::IsNullOrWhiteSpace($WorkingDirectory)) {
                throw (New-Object System.ArgumentNullException("The working directory you provided is just whitespace."))
            }

            $WorkingDirectory = $WorkingDirectory.Trim()

            # Check if the working directory exists at the specified path
            if (!(Test-Path -Path $WorkingDirectory -PathType Container -ErrorAction SilentlyContinue)) {
                throw (New-Object System.IO.FileNotFoundException("Unable to find '$WorkingDirectory'."))
            }
        }

        # Validate that a timeout value is provided
        if (!$Timeout) {
            throw (New-Object System.ArgumentNullException("You must provide a timeout value."))
        }

        # Check if the file path is not rooted and does not exist in the current directory
        if (!([System.IO.Path]::IsPathRooted($FilePath)) -and !(Test-Path -Path $FilePath -PathType Leaf -ErrorAction SilentlyContinue)) {
            # Retrieve the system PATH environment variable and split it into directories
            $EnvPaths = [System.Environment]::GetEnvironmentVariable("PATH").Split(";")
            # Retrieve the PATHEXT environment variable to get executable file extensions
            $PathExts = [System.Environment]::GetEnvironmentVariable("PATHEXT").Split(";")

            $ResolvedPath = $null
            # Iterate through each directory in the PATH environment variable
            foreach ($Directory in $EnvPaths) {
                # Check for each possible file extension in PATHEXT
                foreach ($FileExtension in $PathExts) {
                    # Construct the potential file path
                    $PotentialMatch = Join-Path $Directory ($FilePath + $FileExtension)
                    # If the file exists, set it as the resolved path
                    if (Test-Path $PotentialMatch -PathType Leaf) {
                        $ResolvedPath = $PotentialMatch
                        break
                    }
                }
                # Exit the loop if a resolved path is found
                if ($ResolvedPath) { break }
            }

            # If a resolved path is found, update the FilePath variable
            if ($ResolvedPath) {
                $FilePath = $ResolvedPath
            }
        }

        # Check if the file exists at the specified path
        if (!(Test-Path -Path $FilePath -PathType Leaf -ErrorAction SilentlyContinue)) {
            throw (New-Object System.IO.FileNotFoundException("Unable to find '$FilePath'."))
        }

        # Ensure the timeout value is at least 30 seconds
        if ($Timeout -lt 30) {
            throw (New-Object System.ArgumentOutOfRangeException("You must provide a timeout value that is greater than or equal to 30 seconds."))
        }

        # Initialize a ProcessStartInfo object to configure the process
        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcessInfo.FileName = $FilePath

        # Combine arguments into a single string if provided
        if ($ArgumentList) {
            $ProcessInfo.Arguments = $ArgumentList -join " "
        }

        # Configure the process to run without a shell, without a new window, and with redirected I/O
        $ProcessInfo.UseShellExecute = $False
        $ProcessInfo.CreateNoWindow = $True
        $ProcessInfo.RedirectStandardInput = $True
        $ProcessInfo.RedirectStandardOutput = $True
        $ProcessInfo.RedirectStandardError = $True

        if ($WorkingDirectory) {
            $ProcessInfo.WorkingDirectory = $WorkingDirectory
        }

        # Set the encoding for standard output and error streams
        if (!$Encoding) {
            try {
                # Dynamically load the method to get the OEM code page if not already loaded
                if (-not ([System.Management.Automation.PSTypeName]'NativeMethods.Win32').Type) {
                    $Definition = '[DllImport("kernel32.dll")]' + "`n" + 'public static extern uint GetOEMCP();'
                    Add-Type -MemberDefinition $Definition -Name "Win32" -Namespace "NativeMethods" -ErrorAction Stop
                }

                # Retrieve the OEM code page and set the encoding
                [int]$OemCodePage = [NativeMethods.Win32]::GetOEMCP()
                $Encoding = [System.Text.Encoding]::GetEncoding($OemCodePage)
            } catch {
                throw $_
            }
        }
        $ProcessInfo.StandardOutputEncoding = $Encoding
        $ProcessInfo.StandardErrorEncoding = $Encoding

        # Create a new process object and attach the ProcessStartInfo configuration
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $ProcessInfo

        # Add properties to store standard output and error streams
        $Process | Add-Member -MemberType NoteProperty -Name StdOut -Value (New-Object System.Collections.Generic.List[string]) -Force | Out-Null
        $Process | Add-Member -MemberType NoteProperty -Name StdErr -Value (New-Object System.Collections.Generic.List[string]) -Force | Out-Null

        # Start the process
        $Process.Start() | Out-Null

        $ProcessTimeout = 0
        $TimeoutInMilliseconds = $Timeout * 1000

        # Initialize string builders to collect output
        $StdOutBuffer = New-Object System.Text.StringBuilder
        $StdErrBuffer = New-Object System.Text.StringBuilder

        # Monitor the process execution and read output/error streams
        while (!$Process.HasExited -and $ProcessTimeout -lt $TimeoutInMilliseconds ) {
            # Read standard output to prevent buffer overflow
            while (!$Process.StandardOutput.EndOfStream -and $Process.StandardOutput.Peek() -ne -1) {
                $Char = $Process.StandardOutput.Read()
                if ($Char -ne -1) {
                    $ActualCharacter = [char]$Char
                    if ($ActualCharacter -eq "`n") {
                        # Add the completed line to the StdOut collection
                        $Process.StdOut.Add($StdOutBuffer.ToString())
                        $StdOutBuffer.Length = 0
                    } elseif ($ActualCharacter -ne "`r") {
                        # Append characters to the buffer, excluding carriage returns
                        $null = $StdOutBuffer.Append($ActualCharacter)
                    }
                }
            }

            # Read standard error to prevent buffer overflow
            while (!$Process.StandardError.EndOfStream -and $Process.StandardError.Peek() -ne -1) {
                $Char = $Process.StandardError.Read()
                if ($Char -ne -1) {
                    $ActualCharacter = [char]$Char
                    if ($ActualCharacter -eq "`n") {
                        # Add the completed line to the StdErr collection
                        $Process.StdErr.Add($StdErrBuffer.ToString())
                        $StdErrBuffer.Length = 0
                    } elseif ($ActualCharacter -ne "`r") {
                        # Append characters to the buffer, excluding carriage returns
                        $null = $StdErrBuffer.Append($ActualCharacter)
                    }
                }
            }

            # Sleep briefly before polling again to avoid excessive CPU usage
            Start-Sleep -Milliseconds 100
            $ProcessTimeout = $ProcessTimeout + 10
        }

        # Add final buffered content to StdOut and StdErr properties
        if ($StdOutBuffer.Length -gt 0) {
            $Process.StdOut.Add($StdOutBuffer.ToString())
        }

        if ($StdErrBuffer.Length -gt 0) {
            $Process.StdErr.Add($StdErrBuffer.ToString())
        }

        try {
            # Handle timeout scenarios
            if ($ProcessTimeout -ge 300000) {
                throw (New-Object System.ServiceProcess.TimeoutException("The process has timed out."))
            }

            # Wait for the process to exit within the remaining timeout period
            $TimeoutRemaining = 300000 - $ProcessTimeout
            if (!$Process.WaitForExit($TimeoutRemaining)) {
                throw (New-Object System.ServiceProcess.TimeoutException("The process has timed out."))
            }
        } catch {
            # Set the global exit code and dispose of the process
            if ($Process.ExitCode) {
                $GLOBAL:LASTEXITCODE = $Process.ExitCode
            } else {
                $GLOBAL:LASTEXITCODE = 1
            }

            # Dispose of the process to release resources
            if ($Process) {
                $Process.Dispose()
            }

            throw $_
        }

        # Final read of output and error streams to ensure all data is captured
        while (!$Process.StandardOutput.EndOfStream) {
            $Char = $Process.StandardOutput.Read()
            if ($Char -ne -1) {
                $ActualCharacter = [char]$Char
                if ($ActualCharacter -eq "`n") {
                    # Add the completed line to the StdOut collection
                    $Process.StdOut.Add($StdOutBuffer.ToString())
                    $StdOutBuffer.Length = 0
                } elseif ($ActualCharacter -ne "`r") {
                    # Append characters to the buffer, excluding carriage returns
                    $null = $StdOutBuffer.Append($ActualCharacter)
                }
            }
        }

        while (!$Process.StandardError.EndOfStream) {
            $Char = $Process.StandardError.Read()
            if ($Char -ne -1) {
                $ActualCharacter = [char]$Char
                if ($ActualCharacter -eq "`n") {
                    # Add the completed line to the StdErr collection
                    $Process.StdErr.Add($StdErrBuffer.ToString())
                    $StdErrBuffer.Length = 0
                } elseif ($ActualCharacter -ne "`r") {
                    # Append characters to the buffer, excluding carriage returns
                    $null = $StdErrBuffer.Append($ActualCharacter)
                }
            }
        }

        if ($Process.StdErr.Count -gt 0) {
            # Set the global exit code
            if ($Process.ExitCode -or $Process.ExitCode -eq 0) {
                $GLOBAL:LASTEXITCODE = $Process.ExitCode
            }

            # Dispose of the process
            if ($Process) {
                $Process.Dispose()
            }

            # Log errors from the standard error stream
            $Process.StdErr | Write-Error -Category "FromStdErr"
        }

        # Return the standard output if available
        if ($Process.StdOut.Count -gt 0) {
            $Process.StdOut
        }

        # Set the global exit code
        if ($Process.ExitCode -or $Process.ExitCode -eq 0) {
            $GLOBAL:LASTEXITCODE = $Process.ExitCode
        }

        # Dispose of the process
        if ($Process) {
            $Process.Dispose()
        }
    }

    function Get-DotNet8LatestVersion {
        [CmdletBinding()]
        param ()

        # Download URL for the .NET 8 releases JSON file
        $DownloadURL = "https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/8.0/releases.json"

        # Temporary path to store the downloaded JSON file
        $DestinationPath = "$env:TEMP\DotNet8Releases.json"

        # Download the .NET 8 releases JSON to a temporary file
        try {
            Invoke-Download -URL $DownloadURL -Path "$DestinationPath" -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null
        }
        catch {
            throw $_
        }

        # Error if the file was not downloaded successfully
        if (-not (Test-Path "$DestinationPath" -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::New("Failed to download the .NET 8 releases JSON file from '$DownloadURL'.")
        }

        # Convert the JSON content to a PowerShell object
        try {
            $ReleasesJSON = Get-Content "$DestinationPath" -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw $_
        }

        # Delete the temporary JSON file
        try {
            Remove-Item -Path $DestinationPath -Force -ErrorAction Stop
        }
        catch {
            Write-Error -Category "CleanupError" -Message "Failed to delete the temporary file at '$DestinationPath': '$($_.Exception.Message)'"
        }

        # Parse the JSON to retrieve the latest .NET 8 version details
        $LatestVersion = $ReleasesJSON."latest-release"
        $LatestReleaseObject = $ReleasesJSON.releases | Where-Object { $_."release-version" -eq $LatestVersion }
        $LatestReleaseDetails = $LatestReleaseObject.windowsdesktop.files | Where-Object { $_.name -match "x64.exe$" }

        $LatestReleaseDownloadURL = $LatestReleaseDetails.url
        $LatestReleaseSha512Hash = $LatestReleaseDetails.hash

        return [PSCustomObject]@{
            Version     = $LatestVersion
            DownloadURL = $LatestReleaseDownloadURL
            Hash        = $LatestReleaseSha512Hash
        }
    }

    function Test-IsSystem {
        [CmdletBinding()]
        param ()

        # Get the current Windows identity of the user running the script
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()

        # Check if the current identity's name matches "NT AUTHORITY*"
        # or if the identity represents the SYSTEM account
        return $id.Name -like "NT AUTHORITY*" -or $id.IsSystem
    }

    function Test-IsElevated {
        [CmdletBinding()]
        param ()

        # Get the current Windows identity of the user running the script
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()

        # Create a WindowsPrincipal object based on the current identity
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)

        # Check if the current user is in the Administrator role
        # The function returns $True if the user has administrative privileges, $False otherwise
        # 544 is the value for the Built In Administrators role
        # Reference: https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.windowsbuiltinrole
        $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]'544')
    }
    #endregion

    if (!$ExitCode) {
        $ExitCode = 0
    }
}
process {
    # Attempt to determine if the current session is running with Administrator privileges.
    try {
        $IsElevated = Test-IsElevated -ErrorAction Stop
    }
    catch {
        Write-Host -Object "[Error] $($_.Exception.Message)"
        Write-Host -Object "[Error] Unable to determine if the account '$env:Username' is running this script in an elevated session."
        exit 1
    }

    if (!$IsElevated) {
        Write-Host -Object "[Error] The user '$env:USERNAME' is not running this script in an elevated session. Please run this script as System or in an elevated session."
        exit 1
    }

    # Attempt to determine if the current session is running as the System account
    try {
        $IsSystem = Test-IsSystem -ErrorAction Stop
    }
    catch {
        Write-Host -Object "[Error] $($_.Exception.Message)"
        Write-Host -Object "[Error] Unable to determine if the account '$env:Username' is running this script as the System account."
        exit 1
    }

    # Error if not running as SYSTEM
    if (-not $IsSystem) {
        Write-Host -Object "[Error] Please run this script as the SYSTEM account."
        exit 1
    }

    #region Validate Dell system and create destination folder
    # Retrieve the computer system information
    try {
        $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    }
    catch {
        Write-Host -Object "[Error] Failed to retrieve computer system information."
        Write-Host -Object "[Error] $($_.Exception.Message)"
        exit 1
    }

    # Error if the device is not a Dell system
    if ($ComputerSystem.Manufacturer -notmatch "^Dell") {
        Write-Host -Object "[Error] This script is intended to be run on Dell systems only. The current system manufacturer is '$($ComputerSystem.Manufacturer)'."
        exit 1
    }

    # If the destination directory does not exist, create it
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
    # Retrieve the list of supported Dell models from the Dell Command Update catalog
    try {
        $SupportedModels = Get-DellSupportedModels -DestinationFolder $DestinationFolderPath -ErrorAction Stop
    }
    catch {
        Write-Host -Object "[Error] Failed to retrieve the list of supported Dell models."
        Write-Host -Object "[Error] $($_.Exception.Message)"
        exit 1
    }

    # Get the current device's SKU
    $ComputerSKU = $ComputerSystem.SystemSKUNumber

    # Error if the device's SKU is not supported by DCU
    if ($ComputerSKU -notin $SupportedModels.SKU) {
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

    #region Find/Install DCU CLI
    # Find the dcu-cli.exe
    $DCUCLIPath = Get-Item -Path "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe", "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName -ErrorAction SilentlyContinue

    # If the dcu-cli.exe cannot be found, and the install switch is not provided, error out
    if (-not $DCUCLIPath -and -not $InstallDCUAndDotNet8IfNeeded) {
        Write-Host -Object "[Error] Dell Command Update is not installed on this system. Please use the 'Install Dell Command Update If Needed' parameter to install Dell Command Update."
        exit 1
    }
    elseif (-not $DCUCLIPath -and $InstallDCUAndDotNet8IfNeeded) {
        #region Check for/install .NET
        # If the dcu-cli.exe cannot be found and the install switch is provided, proceed to install it
        Write-Host -Object "[Info] Dell Command Update is not installed. Installing the latest version of Dell Command Update.`n"

        # Define the required .NET Desktop Runtime version
        $RequiredDotNetVersion = [version]"8.0.8"

        # Define the path to check for installed 64 bit .NET Desktop Runtime versions
        $DotNetPath = "$env:ProgramFiles\dotnet\shared\Microsoft.WindowsDesktop.App\"

        # Check for installed .NET Desktop Runtime versions
        if (Test-Path -Path $DotNetPath) {
            try {
                $VersionFolders = Get-ChildItem -Path $DotNetPath -Directory -ErrorAction Stop
            }
            catch {
                Write-Host -Object "[Error] Failed to retrieve .NET Desktop Runtime versions from path '$DotNetPath'."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }

            foreach ($Folder in $VersionFolders) {
                # Determine if this folder has any child items
                try {
                    $ChildItems = Get-ChildItem -Path $Folder.FullName -ErrorAction Stop
                }
                catch {
                    Write-Host -Object "[Warning] Failed to retrieve child items from .NET Desktop Runtime version folder '$($Folder.FullName)'."
                    Write-Host -Object "[Warning] $($_.Exception.Message)"
                    continue
                }

                # Skip to the next folder if this one is empty
                if (-not $ChildItems) {
                    continue
                }

                # Retrieve the version from the folder name
                $Version = $Folder.Name

                # Cast the version string to a [version] object, skipping if there is an error converting
                try {
                    [version]$Version = $Version
                }
                catch {
                    Write-Host -Object "[Warning] Cannot cast version '$Version' to a version object: $($_.Exception.Message)"
                }

                # Dell Command Update requires an 8.x version of the .NET Desktop Runtime, and minimum version of 8.0.8
                if ($Version.Major -eq 8 -and $_.Version -ge $RequiredDotNetVersion) {
                    Write-Host -Object "[Info] Detected .NET Desktop Runtime version $Version installed at '$($Folder.FullName)'."
                    $IsDotNetInstalled = $True
                }
            }
        }

        # If the required .NET version is not installed, proceed to install it
        if (-not $IsDotNetInstalled) {
            Write-Host -Object "[Info] Dell Command Update requires .NET Desktop Runtime 8 (64-bit), with version 8.0.8 or higher, but it is not installed."
            Write-Host -Object "[Info] The latest version of .NET Desktop Runtime 8 (64-bit) will be installed.`n"

            try {
                $LatestDotNetInfo = Get-DotNet8LatestVersion -ErrorAction Stop
            }
            catch {
                Write-Host -Object "[Error] Failed to retrieve the latest .NET 8 version information."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }

            $DotNetDesktop64BitInstaller = $LatestDotNetInfo.DownloadURL
            $DotNetDesktop64BitVersion = $LatestDotNetInfo.Version
            $DotNetDesktop64BitInstallerFilePath = "$DestinationFolderPath\DotNetDesktop64BitInstaller.exe"

            # Download the .NET Desktop Runtime installer
            try {
                Write-Host -Object "[Info] Downloading the .NET Desktop Runtime $DotNetDesktop64BitVersion installer to '$DotNetDesktop64BitInstallerFilePath'."
                Invoke-Download -URL "$DotNetDesktop64BitInstaller" -Path "$DotNetDesktop64BitInstallerFilePath" -UserAgent "Chrome" -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Host -Object "[Error] Failed to download the .NET Desktop Runtime $DotNetDesktop64BitVersion installer."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }

            # Retrieve the SHA512 hash of the .NET installer file
            try {
                $DownloadedDotNetSha512Hash = (Get-FileHash -Path "$DotNetDesktop64BitInstallerFilePath" -Algorithm SHA512 -ErrorAction Stop).Hash
            }
            catch {
                Write-Host -Object "[Error] Failed to compute the SHA512 hash of the downloaded .NET Desktop Runtime installer."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }

            $ExpectedDotNetSha512Hash = $LatestDotNetInfo.Hash

            # Verify the hash of the downloaded .NET installer
            if ($DownloadedDotNetSha512Hash -eq $ExpectedDotNetSha512Hash) {
                Write-Host -Object "[Info] Successfully verified the SHA512 hash of the .NET Desktop Runtime installer."
            }
            else {
                Write-Host -Object "[Error] The SHA512 hash of the downloaded .NET Desktop Runtime installer does not match the expected value."
                Write-Host -Object "[Error] Expected: $ExpectedDotNetSha512Hash"
                Write-Host -Object "[Error] Actual:   $DownloadedDotNetSha512Hash"
                Write-Host -Object "[Error] The installer may be corrupted or tampered with. Aborting installation."
                exit 1
            }

            # Verify the digital signature of the .NET installer
            try {
                $FileSignature = Get-AuthenticodeSignature -FilePath "$DotNetDesktop64BitInstallerFilePath" -ErrorAction Stop
            }
            catch {
                Write-Host -Object "[Error] $($_.Exception.Message)"
                Write-Host -Object "[Error] Failed to check the file signature of '$DotNetDesktop64BitInstallerFilePath'."
                exit 1
            }

            # Validate the signature status and issuer
            if ($FileSignature.Status -ne "Valid") {
                Write-Host -Object "[Error] The file signature of '$DotNetDesktop64BitInstallerFilePath' is $($FileSignature.Status)."
                exit 1
            }

            if ($FileSignature.SignerCertificate.IssuerName.Name -notmatch "Microsoft Corporation") {
                Write-Host -Object "[Error] The file signature of '$DotNetDesktop64BitInstallerFilePath' has an issuer name of '$($FileSignature.SignerCertificate.IssuerName.Name)'."
                Write-Host -Object "[Error] 'Microsoft Corporation' was expected."
                exit 1
            }

            if ($FileSignature.SignerCertificate.Subject -notmatch "Microsoft Corporation") {
                Write-Host -Object "[Error] The file signature of '$DotNetDesktop64BitInstallerFilePath' has a subject of '$($FileSignature.SignerCertificate.Subject)'."
                Write-Host -Object "[Error] 'Microsoft Corporation' was expected."
                exit 1
            }

            Write-Host "[Info] Successfully verified the digital signature of the .NET Desktop Runtime installer."

            # Install the .NET Desktop Runtime
            try {
                Write-Host -Object "[Info] Starting the .NET Desktop Runtime $DotNetDesktop64BitVersion installer process."
                Start-Process -FilePath "$DotNetDesktop64BitInstallerFilePath" -ArgumentList "/install /quiet /norestart /log `"$DestinationFolderPath\DotNetDesktop64BitInstallerLog.log`"" -Wait -NoNewWindow -ErrorAction Stop

                if ($LASTEXITCODE -ne 0) {
                    Write-Host -Object "[Error] .NET Desktop Runtime installer exited with code $LASTEXITCODE."
                    Write-Host -Object "[Error] Please see the error log at '$DestinationFolderPath\DotNetDesktop64BitInstallerLog.log' for more information."
                    exit 1
                }

                Write-Host -Object "[Info] Successfully installed .NET Desktop Runtime $DotNetDesktop64BitVersion.`n"

                # Retrieve the files to be removed (installer and log files)
                $FilesToRemove = Get-ChildItem $DestinationFolderPath\DotNetDesktop64Bit* -ErrorAction SilentlyContinue

                # Remove each file individually to handle any errors
                foreach ($file in $filesToRemove) {
                    try {
                        Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    }
                    catch {
                        Write-Host -Object "[Warning] Failed to delete the file at '$($file.FullName)'. Please delete this file manually."
                        Write-Host -Object "[Warning] $($_.Exception.Message)"
                    }
                }
            }
            catch {
                Write-Host -Object "[Error] Failed to start the .NET Desktop Runtime $DotNetDesktop64BitVersion installer."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }
        }
        else {
            Write-Host -Object "[Info] .NET Desktop Runtime 8.0.8 or higher is already installed.`n"
        }
        #endregion

        #region Find/install DCU
        # Determine the download URL and hash for the Dell Command Update installer
        try {
            $LatestDellCommandUpdate = Get-DellAvailableUpdates -SystemSKU $ComputerSKU -DestinationFolder $DestinationFolderPath -Method "CatalogDownload" -Latest -ErrorAction Stop | Where-Object { $_.Name -match "Command.+Windows Universal" }
        }
        catch {
            Write-Host -Object "[Warning] Failed to retrieve the latest Dell Command Update download URL for the SKU of '$ComputerSKU'."
            Write-Host -Object "[Warning] $($_.Exception.Message)"
            Write-Host -Object "[Warning] The script will fallback to a hardcoded download URL for version 5.5.0.`n"
            $PrintedDCUDownloadURLWarning = $True
        }

        # Extract the download URL, hashes and version from the retrieved DCU installer information
        $DellCommandUpdateDownloadURL = $LatestDellCommandUpdate.DownloadURL
        $ExpectedDCUSha256Hash = $LatestDellCommandUpdate.DownloadHashSha256
        $ExpectedDCUSha1Hash = $LatestDellCommandUpdate.DownloadHashSha1
        $ExpectedDCUMd5Hash = $LatestDellCommandUpdate.DownloadHashMD5
        $DellCommandUpdateVersion = $LatestDellCommandUpdate.VendorVersion

        # If the latest version is blank, fallback to the hardcoded URL for version 5.5.0
        if ([string]::IsNullOrWhiteSpace($DellCommandUpdateDownloadURL)) {
            # Only print the warning if it wasn't already printed from the catch block
            if (-not $PrintedDCUDownloadURLWarning) {
                Write-Host -Object "[Warning] Failed to retrieve the latest Dell Command Update download URL for the SKU of '$ComputerSKU'."
                Write-Host -Object "[Warning] The script will fallback to a hardcoded download URL for version 5.5.0.`n"
            }
            $DellCommandUpdateDownloadURL = "https://dl.dell.com/FOLDER13309588M/2/Dell-Command-Update-Windows-Universal-Application_C8JXV_WIN64_5.5.0_A00_01.EXE"
            $ExpectedDCUSha256Hash = "017D24D38D758FE1D585EA895BB285FAD4488AAF95E2BE343BFB88E6B3345CB3"
            $DellCommandUpdateVersion = "5.5.0"
        }

        $DellCommandUpdateInstallerFilePath = "$DestinationFolderPath\DellCommandUpdateInstaller.exe"

        # Download the Dell Command Update installer
        try {
            Write-Host -Object "[Info] Downloading the Dell Command Update version $DellCommandUpdateVersion installer to '$DellCommandUpdateInstallerFilePath'."
            Invoke-Download -URL "$DellCommandUpdateDownloadURL" -Path "$DellCommandUpdateInstallerFilePath" -UserAgent "Chrome" -Attempts 3 -SkipSleep -Overwrite -Quiet -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host -Object "[Error] Failed to download Dell Command Update."
            Write-Host -Object "$($_.Exception.Message)"
            exit 1
        }

        # Determine the hash algorithm to use for verifying the DCU installer file
        # Prefer SHA256 > SHA1 > MD5
        # Invalid hashes are represented by a single hyphen ("-") in the catalog
        if ($ExpectedDCUSha256Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedDCUSha256Hash)) {
            $HashAlgorithmToCheck = "SHA256"
            $ExpectedDCUHash = $ExpectedDCUSha256Hash
        }
        elseif ($ExpectedDCUSha1Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedDCUSha1Hash)) {
            $HashAlgorithmToCheck = "SHA1"
            $ExpectedDCUHash = $ExpectedDCUSha1Hash
        }
        elseif ($ExpectedDCUMd5Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedDCUMd5Hash)) {
            $HashAlgorithmToCheck = "MD5"
            $ExpectedDCUHash = $ExpectedDCUMd5Hash
        }
        else {
            Write-Host -Object "[Error] No valid hash found in the catalog to verify the integrity of the Dell Command Update installer.`n"
            Write-Host -Object "[Error] DCU cannot be installed."

            # Remove the installer file
            try {
                Remove-Item -Path "$DellCommandUpdateInstallerFilePath" -Force -ErrorAction Stop
            }
            catch {
                Write-Host -Object "[Warning] Failed to delete the update file at '"$DellCommandUpdateInstallerFilePath"'. Please delete this file manually."
                Write-Host -Object "[Warning] $($_.Exception.Message)"
            }

            exit 1
        }

        # Retrieve the hash of the DCU installer file
        try {
            $DownloadedDCUHash = (Get-FileHash -Path "$DellCommandUpdateInstallerFilePath" -Algorithm $HashAlgorithmToCheck -ErrorAction Stop).Hash
        }
        catch {
            Write-Host -Object "[Error] Failed to compute the $HashAlgorithmToCheck hash of the downloaded Dell Command Update installer."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            exit 1
        }

        # Verify the hash of the downloaded Dell Command Update installer
        if ($DownloadedDCUHash -eq $ExpectedDCUHash) {
            Write-Host -Object "[Info] Successfully verified the $HashAlgorithmToCheck hash of the Dell Command Update installer."
        }
        else {
            Write-Host -Object "[Error] The $HashAlgorithmToCheck hash of the downloaded Dell Command Update installer does not match the expected value."
            Write-Host -Object "[Error] Expected: $ExpectedDCUHash"
            Write-Host -Object "[Error] Actual:   $DownloadedDCUHash"
            Write-Host -Object "[Error] The installer may be corrupted or tampered with. Aborting installation."

            # Remove the installation file
            try {
                Remove-Item -Path "$DellCommandUpdateInstallerFilePath" -Force -ErrorAction Stop
            }
            catch {
                Write-Host -Object "[Warning] Failed to delete the update file at '"$DellCommandUpdateInstallerFilePath"'. Please delete this file manually."
                Write-Host -Object "[Warning] $($_.Exception.Message)"
            }

            exit 1
        }

        # Verify the digital signature of the DCU installer
        try {
            $FileSignature = Get-AuthenticodeSignature -FilePath "$DellCommandUpdateInstallerFilePath" -ErrorAction Stop
        }
        catch {
            Write-Host -Object "[Error] $($_.Exception.Message)"
            Write-Host -Object "[Error] Failed to check the file signature of '$DellCommandUpdateInstallerFilePath'."
            exit 1
        }

        # Validate the signature status and issuer
        if ($FileSignature.Status -ne "Valid") {
            Write-Host -Object "[Error] The file signature of '$DellCommandUpdateInstallerFilePath' is $($FileSignature.Status)."
            exit 1
        }

        if ($FileSignature.SignerCertificate.IssuerName.Name -notmatch "DigiCert, Inc.") {
            Write-Host -Object "[Error] The file signature of '$DellCommandUpdateInstallerFilePath' has an issuer name of '$($FileSignature.SignerCertificate.IssuerName.Name)'."
            Write-Host -Object "[Error] 'DigiCert, Inc.' was expected."
            exit 1
        }

        if ($FileSignature.SignerCertificate.Subject -notmatch "Dell Technologies Inc.") {
            Write-Host -Object "[Error] The file signature of '$DellCommandUpdateInstallerFilePath' has a subject of '$($FileSignature.SignerCertificate.Subject)'."
            Write-Host -Object "[Error] 'Dell Technologies Inc.' was expected."
            exit 1
        }

        Write-Host "[Info] Successfully verified the digital signature of the Dell Command Update installer."

        # Install Dell Command Update
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
            Write-Host -Object "[Error] The Dell Command Update installer exited with code $($DCUInstallerProcess.ExitCode). The log file at '$DestinationFolderPath\DellCommandUpdateInstallerLog.log' may have more information."
            exit 1
        }

        Write-Host -Object "[Info] Successfully installed Dell Command Update version $DellCommandUpdateVersion.`n"

        # Retrieve the files to be removed (installer and log files)
        $FilesToRemove = Get-ChildItem "$DestinationFolderPath\DellCommandUpdateInstaller*" -ErrorAction SilentlyContinue

        # Remove each file individually to handle any errors
        foreach ($file in $filesToRemove) {
            try {
                Remove-Item -Path $file.FullName -Force -ErrorAction Stop
            }
            catch {
                Write-Host -Object "[Warning] Failed to delete the file at '$($file.FullName)'. Please delete this file manually."
                Write-Host -Object "[Warning] $($_.Exception.Message)"
            }
        }
        #endregion

        # Try to find the dcu-cli.exe again
        $DCUCLIPath = Get-Item -Path "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe", "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName -ErrorAction SilentlyContinue

        if (-not $DCUCLIPath) {
            Write-Host -Object "[Error] 'dcu-cli.exe' still cannot be found after install. Please verify that Dell Command Update installed correctly."
            exit 1
        }
    }
    #endregion

    #region Scan for updates
    # Initialize a list to store the updates
    $UpdatesList = New-Object System.Collections.Generic.List[PSObject]

    # Use the dcu-cli.exe to retrieve the list of available updates for this system and add each one to the updates list
    try {
        Write-Host -Object "[Info] Scanning for available updates."
        Get-DellAvailableUpdates -Method "CLI" -DestinationFolder $DestinationFolderPath -ErrorAction Stop | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                $UpdatesList.Add($_)
            }
        }
    }
    catch {
        Write-Host -Object "[Error] Failed to retrieve the list of available updates using dcu-cli.exe. The log file at '$DestinationFolderPath\DCUScan.log' may have more information."
        Write-Host -Object "[Error] $($_.Exception.Message)"
        exit 1
    }

    # Count the number of available updates
    $InitialAvailableUpdatesCount = ($UpdatesList | Measure-Object).Count

    Write-Host -Object "[Info] Found $InitialAvailableUpdatesCount available updates for this system."

    # If there are updates to report, output the available updates list to the activity feed
    if ($InitialAvailableUpdatesCount -gt 0) {
        Write-Host ""
        ($UpdatesList | Select-Object -Property PackageID, Name, Type, Category, Version, ReleaseDate, Severity, Status | Format-List | Out-String).Trim() | Write-Host
    }
    #endregion

    #region Install updates
    # If there are updates available and any installation parameters were provided, proceed to install updates
    if ($InitialAvailableUpdatesCount -gt 0 -and ($InstallAllUpdates -or $ValidatedPackageIDs -or $InstallUpdatesByCategory -or $InstallUpdatesBySeverity -or $InstallUpdatesByType)) {
        Write-Host ""

        # Create a copy of the available updates to filter down as needed
        $UpdatesToInstall = $UpdatesList.PSObject.Copy()

        #region Filter updates to install
        # If verified package IDs were provided, filter the updates to only those package IDs
        if ($ValidatedPackageIDs) {
            $ValidatedPackageIDs | Where-Object { $_ -notin $UpdatesToInstall.PackageID } | ForEach-Object {
                Write-Host -Object "[Warning] The specified Package ID '$_' was not found in the list of available updates. It will not be installed."
                $InvalidPackageIDs.Add($_)
                $AddNewLine = $True
            }

            $UpdatesToInstall = $UpdatesToInstall | Where-Object { $_.PackageID -in $ValidatedPackageIDs }

            # Add new line if any warnings were printed
            if ($AddNewLine) {
                Write-Host ""
            }
        }

        # If an update type was specified, filter the updates to only that type
        if (-not $ValidatedPackageIDs -and $InstallUpdatesByType) {
            $UpdatesToInstall = $UpdatesToInstall | Where-Object { $_.Type -eq $InstallUpdatesByType }
        }

        # If an update category was specified, filter the updates to only that category
        if (-not $ValidatedPackageIDs -and $InstallUpdatesByCategory) {
            $UpdatesToInstall = $UpdatesToInstall | Where-Object { $_.Category -eq $InstallUpdatesByCategory }
        }

        # If a device severity was specified, filter the updates to only that severity
        if (-not $ValidatedPackageIDs -and $InstallUpdatesBySeverity) {
            $UpdatesToInstall = $UpdatesToInstall | Where-Object { $_.Severity -match $InstallUpdatesBySeverity }
        }
        #endregion

        # If no updates remain after filtering, print an error
        if (-not $UpdatesToInstall) {
            Write-Host -Object "[Error] No updates found that match the specified criteria. No updates will be installed.`n"
            $ExitCode = 1
        }
        else {
            # Initialize a list to track successful updates
            $SuccessfulUpdates = New-Object System.Collections.Generic.List[string]

            # Initialize a list to track updates that need reboots to complete installation
            $RebootRequiredUpdates = New-Object System.Collections.Generic.List[string]

            # Initialize a list to track failed updates
            $FailedUpdates = New-Object System.Collections.Generic.List[string]

            # Initialize the reboot required variable
            $RebootRequired = $false

            Write-Host -Object "[Info] The following updates will be installed: $($UpdatesToInstall.Name -join ", ").`n"

            # Retrieve the updates catalog for this device to get the expected hashes
            try {
                $UpdateCatalog = Get-DellAvailableUpdates -SystemSKU $ComputerSKU -DestinationFolder $DestinationFolderPath -Method "CatalogDownload" -ErrorAction Stop
            }
            catch {
                Write-Host -Object "[Error] Failed to retrieve the Dell updates catalog for this device to verify update file hashes. No updates will be installed."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                $SkipUpdates = $true
                $ExitCode = 1
            }

            #region Update install loop
            if (-not $SkipUpdates) {
                # Loop through each update and attempt to download and install it
                foreach ($Update in $UpdatesToInstall) {
                    # Initialize loop variables
                    $UpdateName = $Update.Name
                    $PackageID = $Update.PackageID
                    $ExpectedUpdateSha256Hash = ($UpdateCatalog | Where-Object { $_.PackageID -eq $PackageID }).DownloadHashSha256
                    $ExpectedUpdateSha1Hash = ($UpdateCatalog | Where-Object { $_.PackageID -eq $PackageID }).DownloadHashSha1
                    $ExpectedUpdateMd5Hash = ($UpdateCatalog | Where-Object { $_.PackageID -eq $PackageID }).DownloadHashMD5
                    $UpdatePath = "$DestinationFolderPath\$PackageID.exe"
                    $LogPath = "$DestinationFolderPath\${PackageID}_InstallLog.log"
                    $LogContent = $null
                    $UpdateExitCode = $null
                    $NameOfExitCode = $null
                    $Result = $null

                    Write-Host "[Info] Working on the '$UpdateName' update."

                    # Download the update
                    try {
                        Invoke-Download -URL $Update.DownloadURL -Path $UpdatePath -UserAgent "Chrome" -Attempts 3 -Overwrite -Quiet -SkipSleep -ErrorAction Stop | Out-Null
                    }
                    catch {
                        Write-Host -Object "[Error] Failed to download the update '$UpdateName' at URL '$($Update.DownloadURL)."
                        Write-Host -Object "[Error] $($_.Exception.Message)"
                        $ExitCode = 1
                        continue
                    }

                    # Determine the hash algorithm to use for verification (not all updates have all hash types available)
                    # Prefer SHA256 > SHA1 > MD5
                    # Invalid hashes are represented by a single hyphen ("-") in the catalog
                    if ($ExpectedUpdateSha256Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedUpdateSha256Hash)) {
                        $HashAlgorithmToCheck = "SHA256"
                        $ExpectedUpdateHash = $ExpectedUpdateSha256Hash
                    }
                    elseif ($ExpectedUpdateSha1Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedUpdateSha1Hash)) {
                        $HashAlgorithmToCheck = "SHA1"
                        $ExpectedUpdateHash = $ExpectedUpdateSha1Hash
                    }
                    elseif ($ExpectedUpdateMd5Hash -ne "-" -and -not [string]::IsNullOrWhiteSpace($ExpectedUpdateMd5Hash)) {
                        $HashAlgorithmToCheck = "MD5"
                        $ExpectedUpdateHash = $ExpectedUpdateMd5Hash
                    }
                    else {
                        Write-Host -Object "[Error] No valid hash found in the catalog to verify the integrity of the downloaded update '$UpdateName'.`n"
                        Write-Host -Object "[Error] The update will not be installed."
                        Write-Host -Object "### Package Information: ###"
                        Write-Host -Object "Package ID: $PackageID"
                        Write-Host -Object "Name:       $UpdateName"
                        Write-Host -Object "System SKU: $ComputerSKU`n"

                        # Remove the installer file
                        try {
                            Remove-Item -Path $UpdatePath -Force -ErrorAction Stop
                        }
                        catch {
                            Write-Host -Object "[Warning] Failed to delete the update file at '$UpdatePath'. Please delete this file manually."
                            Write-Host -Object "[Warning] $($_.Exception.Message)"
                        }

                        # Add the package ID to the list of failed updates
                        $FailedUpdates.Add($PackageID)

                        $ExitCode = 1
                        continue
                    }

                    # Retrieve the hash of the downloaded update
                    try {
                        $DownloadedUpdateHash = (Get-FileHash -Path $UpdatePath -Algorithm $HashAlgorithmToCheck -ErrorAction Stop).Hash
                    }
                    catch {
                        Write-Host -Object "[Error] Failed to compute the $HashAlgorithmToCheck hash of the downloaded update '$UpdateName'."
                        Write-Host -Object "[Error] $($_.Exception.Message)"

                        # Remove the installer file
                        try {
                            Remove-Item -Path $UpdatePath -Force -ErrorAction Stop
                        }
                        catch {
                            Write-Host -Object "[Warning] Failed to delete the update file at '$UpdatePath'. Please delete this file manually."
                            Write-Host -Object "[Warning] $($_.Exception.Message)"
                        }

                        # Add the package ID to the list of failed updates
                        $FailedUpdates.Add($PackageID)

                        $ExitCode = 1
                        continue
                    }

                    # Verify the hash of the downloaded update
                    if ($ExpectedUpdateHash -ne $DownloadedUpdateHash) {
                        Write-Host -Object "[Error] The $HashAlgorithm hash of the downloaded update '$UpdateName' does not match the expected value."
                        Write-Host -Object "[Error] Expected: $ExpectedUpdateHash"
                        Write-Host -Object "[Error] Actual:   $DownloadedUpdateHash"
                        Write-Host -Object "[Error] The installer may be corrupted or tampered with. Aborting installation of this update.`n"

                        # Remove the installer file
                        try {
                            Remove-Item -Path $UpdatePath -Force -ErrorAction Stop
                        }
                        catch {
                            Write-Host -Object "[Warning] Failed to delete the update file at '$UpdatePath'. Please delete this file manually."
                            Write-Host -Object "[Warning] $($_.Exception.Message)"
                        }

                        # Add the package ID to the list of failed updates
                        $FailedUpdates.Add($PackageID)

                        $ExitCode = 1
                        continue
                    }
                    else {
                        Write-Host -Object "[Info] Successfully verified the update's $HashAlgorithmToCheck hash."
                    }

                    # Retrieve the digital signature of the update
                    try {
                        $FileSignature = Get-AuthenticodeSignature -FilePath "$UpdatePath" -ErrorAction Stop
                    }
                    catch {
                        Write-Host -Object "[Error] Failed to check the file signature of '$UpdatePath'. It will not be installed."
                        Write-Host -Object "[Error] $($_.Exception.Message)"

                        # Remove the installer file
                        try {
                            Remove-Item -Path $UpdatePath -Force -ErrorAction Stop
                        }
                        catch {
                            Write-Host -Object "[Warning] Failed to delete the update file at '$UpdatePath'. Please delete this file manually."
                            Write-Host -Object "[Warning] $($_.Exception.Message)"
                        }

                        # Add the package ID to the list of failed updates
                        $FailedUpdates.Add($PackageID)

                        $ExitCode = 1
                        continue
                    }

                    # Validate the signature status
                    if ($FileSignature.Status -ne "Valid") {
                        Write-Host -Object "[Error] The file signature of '$UpdatePath' is $($FileSignature.Status). It will not be installed."

                        # Remove the installer file
                        try {
                            Remove-Item -Path $UpdatePath -Force -ErrorAction Stop
                        }
                        catch {
                            Write-Host -Object "[Warning] Failed to delete the update file at '$UpdatePath'. Please delete this file manually."
                            Write-Host -Object "[Warning] $($_.Exception.Message)"
                        }

                        # Add the package ID to the list of failed updates
                        $FailedUpdates.Add($PackageID)

                        $ExitCode = 1
                        continue
                    }

                    # Regex strings for valid signature subjects for Dell updates
                    $ValidSignatures = @(
                        "O=Dell Inc.?"
                        "O=Dell Technologies Inc.?"
                        "O=Intel Corporation"
                        "O=Dell USA L.P."
                    )

                    # Combine the strings into a single regex pattern
                    $ValidSignaturesRegex = $ValidSignatures -join "|"

                    # Validate the subject of the certificate
                    if ($FileSignature.SignerCertificate.Subject -notmatch "$ValidSignaturesRegex") {
                        Write-Host -Object "[Error] The file signature of '$UpdatePath' has an invalid subject of '$($FileSignature.SignerCertificate.Subject)'."
                        Write-Host -Object "[Error] Expected a Dell or Intel related subject. The update will not be installed."

                        # Remove the installer file
                        try {
                            Remove-Item -Path $UpdatePath -Force -ErrorAction Stop
                        }
                        catch {
                            Write-Host -Object "[Warning] Failed to delete the update file at '$UpdatePath'. Please delete this file manually."
                            Write-Host -Object "[Warning] $($_.Exception.Message)"
                        }

                        # Add the package ID to the list of failed updates
                        $FailedUpdates.Add($PackageID)

                        $ExitCode = 1
                        continue
                    }

                    Write-Host -Object "[Info] Successfully verified the update's digital signature."

                    # Install the update
                    Write-Host -Object "[Info] Installing the update."
                    try {
                        Start-Process -FilePath $UpdatePath -ArgumentList "/s /l=`"$LogPath`"" -Wait -NoNewWindow -ErrorAction Stop
                    }
                    catch {
                        Write-Host -Object "[Error] Failed to start the installation process for the update '$UpdateName'."
                        Write-Host -Object "[Error] $($_.Exception.Message)"
                        $ExitCode = 1
                    }

                    # Verify the update successfully installed by parsing the log file
                    if (Test-Path -Path $LogPath) {
                        try {
                            $LogContent = (Get-Content -Path $LogPath -ErrorAction Stop | Where-Object { $_ } | Out-String).Trim()
                        }
                        catch {
                            Write-Host -Object "[Error] Failed to read the log file for update '$UpdateName' at path '$LogPath'. Cannot determine if it succeeded or not."
                            Write-Host -Object "[Error] $($_.Exception.Message)"
                            $ExitCode = 1
                        }
                    }
                    else {
                        Write-Host -Object "[Error] The log file for update '$UpdateName' was not found at path '$LogPath'. Cannot determine if it succeeded or not."
                        $ExitCode = 1
                    }

                    # If the log content was successfully read, parse it to determine if the update succeeded or failed
                    if ($LogContent) {
                        # Define the successful exit codes, names of exit codes, and results
                        $SuccessfulExitCodes = @(0, 2)
                        $SuccessfulNamesOfExitCodes = @("SUCCESS", "REBOOT_REQUIRED") -join "|"
                        $SuccessfulResults = @("SUCCESS", "REBOOT") -join "|"

                        # The verification process differs for firmware/BIOS updates vs. other update types
                        switch -Regex ($Update.Type) {
                            "Firmware|BIOS" {
                                try {
                                    $UpdateExitCode = ([regex]::Matches($LogContent, "Exit Code = (?<ExitCode>\d+)") | Select-Object -Last 1).Groups[1].Value
                                    $RebootRequiredFromLog = ([regex]::Matches($LogContent, "Reboot Required"))
                                }
                                catch {
                                    Write-Host -Object "[Error] Failed to parse the log file for update '$UpdateName' at path '$LogPath'. Cannot determine if it succeeded or not."
                                    Write-Host -Object "[Error] $($_.Exception.Message)"
                                    $ExitCode = 1
                                }

                                if ($UpdateExitCode -in $SuccessfulExitCodes) {
                                    Write-Host -Object "[Info] Successfully installed the update.`n"

                                    # Add the package ID to the list of successful updates
                                    $SuccessfulUpdates.Add($PackageID)

                                    # If the update requires a reboot, set the reboot required flag
                                    if (($RebootRequiredFromLog | Measure-Object).Count -gt 0) {
                                        Write-Host -Object "[Info] The update '$UpdateName' requires a reboot to complete the installation.`n"
                                        $RebootRequired = $true

                                        # If the 'Suspend BitLocker and Reboot If Needed' option is not used, add the package ID to the list of updates that require a reboot
                                        if (-not $SuspendBitLockerAndRebootIfNeeded) {
                                            $RebootRequiredUpdates.Add($PackageID)
                                        }
                                    }
                                }
                                else {
                                    Write-Host -Object "[Error] The update failed to install. See the log file at '$LogPath' for more information."
                                    Write-Host -Object "[Error] Exit Code: $UpdateExitCode"
                                    Write-Host -Object "[Error] Reboot Required: $(($RebootRequired | Measure-Object).Count -gt 0)`n"

                                    # Add the package ID to the list of failed updates
                                    $FailedUpdates.Add($PackageID)

                                    $ExitCode = 1
                                }
                            }
                            default {
                                # Parse the log content to extract the exit code, name of exit code, and result
                                try {
                                    $UpdateExitCode = ([regex]::Matches($LogContent, "Exit Code set to: (?<UpdateExitCode>\d+)") | Select-Object -Last 1).Groups[1].Value
                                    $NameOfExitCode = ([regex]::Matches($LogContent, "Name of Exit Code: (?<NameOfExitCode>[^\n\r]*)") | Select-Object -Last 1).Groups[1].Value
                                    $Result = ([regex]::Matches($LogContent, "Result: (?<Result>[^\n\r]*)") | Select-Object -Last 1).Groups[1].Value
                                }
                                catch {
                                    Write-Host -Object "[Error] Failed to parse the log file for update '$UpdateName' at path '$LogPath'. Cannot determine if it succeeded or not."
                                    Write-Host -Object "[Error] $($_.Exception.Message)"
                                    $ExitCode = 1
                                }

                                # If all three values indicate success, the update was successful
                                if ($UpdateExitCode -in $SuccessfulExitCodes -and $NameOfExitCode -match "$SuccessfulNamesOfExitCodes" -and $Result -match "$SuccessfulResults") {
                                    Write-Host -Object "[Info] Successfully installed the update.`n"

                                    # Add the package ID to the list of successful updates
                                    $SuccessfulUpdates.Add($PackageID)

                                    # If the update requires a reboot, set the reboot required flag
                                    if ($NameOfExitCode -match "REBOOT_REQUIRED" -or $Result -match "REBOOT") {
                                        Write-Host -Object "[Info] The update '$UpdateName' requires a reboot to complete the installation.`n"
                                        $RebootRequired = $true

                                        # If the 'Suspend BitLocker and Reboot If Needed' option is not used, add the package ID to the list of updates that require a reboot
                                        if (-not $SuspendBitLockerAndRebootIfNeeded) {
                                            $RebootRequiredUpdates.Add($PackageID)
                                        }
                                    }
                                }
                                else {
                                    Write-Host -Object "[Error] The update failed to install. See the log file at '$LogPath' for more information."
                                    Write-Host -Object "[Error] Exit Code: $UpdateExitCode"
                                    Write-Host -Object "[Error] Name of Exit Code: $NameOfExitCode"
                                    Write-Host -Object "[Error] Result: $Result`n"

                                    # Add the package ID to the list of failed updates
                                    $FailedUpdates.Add($PackageID)

                                    $ExitCode = 1
                                }
                            }
                        }

                        # Remove the log file if the update was successful
                        if ($PackageID -in $SuccessfulUpdates) {
                            try {
                                Remove-Item -Path $LogPath -Force -ErrorAction Stop
                            }
                            catch {
                                Write-Host -Object "[Warning] Failed to delete the log file at path '$LogPath'. Please delete this file manually."
                                Write-Host -Object "[Warning] $($_.Exception.Message)"
                            }
                        }
                    }

                    # Remove the installer file for the update
                    try {
                        Remove-Item -Path $UpdatePath -Force -ErrorAction Stop
                    }
                    catch {
                        Write-Host -Object "[Warning] Failed to delete the installer at path '$UpdatePath'. Please delete this file manually."
                        Write-Host -Object "[Warning] $($_.Exception.Message)"
                    }
                }
            }

            Write-Host -Object "[Info] Finished installing updates.`n"
        }
        #endregion

        # Update the status of each available update based on the installation results
        $UpdatesList | ForEach-Object {
            if ($_.PackageID -in $SuccessfulUpdates -and $_.PackageID -notin $RebootRequiredUpdates) {
                $_.Status = "Installed"
            }
            elseif ($_.PackageID -in $RebootRequiredUpdates) {
                $_.Status = "Installed: Pending Reboot"
            }
            elseif ($_.PackageID -in $FailedUpdates) {
                $_.Status = "Failed to install"
            }
        }

        # Count the number of available, installed, and failed updates
        $AvailableUpdatesCountAfterInstall = ($UpdatesList | Where-Object { $_.Status -notmatch "^Installed" } | Measure-Object).Count
        $InstalledUpdatesCountAfterInstall = ($UpdatesList | Where-Object { $_.Status -match "^Installed" } | Measure-Object).Count
        $FailedUpdatesCountAfterInstall = ($UpdatesList | Where-Object { $_.Status -eq "Failed to install" } | Measure-Object).Count

        Write-Host -Object "[Info] $InstalledUpdatesCountAfterInstall update(s) installed successfully. $FailedUpdatesCountAfterInstall update(s) failed to install. There are now $AvailableUpdatesCountAfterInstall available update(s) for this system.`n"

        # If any updates were installed, output the list of installed updates to the activity feed
        if ($InstalledUpdatesCountAfterInstall -gt 0) {
            Write-Host -Object "[Info] These updates were installed successfully:"
            ($UpdatesList | Where-Object { $_.PackageID -in $SuccessfulUpdates } | Select-Object -ExpandProperty Name | ForEach-Object { "- $_" } | Out-String).Trim() | Write-Host
        }

        # If any updates failed to install, output the list of failed updates to the activity feed
        if ($FailedUpdatesCountAfterInstall -gt 0) {
            Write-Host -Object "`n[Error] These updates failed to install:"
            ($UpdatesList | Where-Object { $_.PackageID -in $FailedUpdates } | Select-Object -ExpandProperty Name | ForEach-Object { "- $_" } | Out-String).Trim() | Write-Host
        }
    }
    #endregion

    # Add any invalid package IDs to the updates list so they can be reported on in the WYSIWYG and multiline fields
    if ($InvalidPackageIDs -and ($MultilineCustomFieldName -or $WysiwygCustomFieldName)) {
        foreach ($PackageID in $InvalidPackageIDs) {
            $InvalidUpdateObject = [PSCustomObject]@{
                PackageID   = $PackageID
                Name        = "Invalid Package ID"
                Type        = "N/A"
                Category    = "N/A"
                Version     = "N/A"
                ReleaseDate = "N/A"
                DownloadURL = "N/A"
                Severity    = "N/A"
                Status      = "Not installed"
            }

            # Add the invalid update object to the list
            $UpdatesList.Add($InvalidUpdateObject)
        }
    }

    #region Set custom fields
    # If provided, write to a WYSIWYG custom field
    if ($WYSIWYGCustomFieldName) {
        if ($UpdatesList) {
            # Generate an HTML table from the updates list, including any invalid package IDs
            $HtmlTable = $UpdatesList | Select-Object -Property PackageID, Name, Type, Category, Version, ReleaseDate, Severity, Status | ConvertTo-Html -Fragment

            # Bold all headers in the HTML table
            $HtmlTable = $HtmlTable -replace "<th>(\w+)</th>", '<th><b>$1</b></th>'

            # Highlight rows with "Urgent" in the Severity column
            $HtmlTable = $HtmlTable | ForEach-Object {
                if ($_ -match "Urgent") {
                    $_ -replace "<tr>", "<tr class='danger'>"
                }
                else {
                    $_
                }
            }

            # Wrap the HTML table in a styled card layout
            $HtmlTable = "<div class='card flex-grow-1'>
                                <div class='card-title-box'>
                                    <div class='card-title'><i class='fa-solid fa-circle-up'></i>&nbsp;&nbsp;Available Dell Updates</div>
                                </div>
                                <div class='card-body' style='white-space: nowrap;'>
                                    $HtmlTable
                                </div>
                            </div>"
        }
        else {
            $HtmlTable = "<p>Dell Command Update found no available updates as of $(Get-Date -Format G).</p>"
        }

        # Attempt to set the custom field
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

    # If provided, write to a multiline custom field
    if ($MultilineCustomFieldName) {
        if ($UpdatesList) {
            # Initialize the multiline text string list
            $MultilineText = New-Object System.Collections.Generic.List[string]

            # Format the available updates in the list and add it to the multiline text
            $MultilineText.Add(($UpdatesList | Where-Object { $_.Name -ne "Invalid Package ID" } | Select-Object -Property PackageID, Name, Type, Category, Version, ReleaseDate, Severity, Status | Format-List | Out-String).Trim())

            # If there are any invalid package IDs, add them to the multiline text
            if ($InvalidPackageIDs) {
                $MultilineText.Add("`n`n")
                $MultilineText.Add(($UpdatesList | Where-Object { $_.Name -eq "Invalid Package ID" } | Select-Object -Property PackageID, Name, Status | Format-List | Out-String).Trim())
            }
        }
        else {
            $MultilineText = "Dell Command Update found no available updates as of $(Get-Date -Format G)."
        }

        # Attempt to set the multiline custom field
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
    # If a reboot is required and the user specified to reboot if needed, schedule a reboot in 60 seconds
    if ($RebootRequired -and $SuspendBitLockerAndRebootIfNeeded) {
        Write-Host ""

        #region Check BitLocker status
        # Check if BitLocker is enabled
        try {
            $BitLockerStatus = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        }
        catch {
            Write-Host -Object "[Warning] Failed to retrieve BitLocker status."
            Write-Host -Object "[Warning] $($_.Exception.Message)"
            Write-Host -Object "[Warning] Proceeding without suspending BitLocker protection."
        }

        # If BitLocker is enabled, suspend protection for the reboot
        if ($BitLockerStatus.VolumeStatus -eq "FullyEncrypted" -and $BitLockerStatus.ProtectionStatus -eq "On") {
            Write-Host -Object "[Info] BitLocker is enabled on this system. Attempting to suspend BitLocker protection on '$env:SystemDrive' for 1 reboot."

            try {
                Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop | Out-Null
                Write-Host -Object "[Info] Successfully suspended BitLocker protection on '$env:SystemDrive'. BitLocker will be re-enabled after the reboot."
            }
            catch {
                Write-Host -Object "[Error] Failed to suspend BitLocker protection on '$env:SystemDrive'."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                $ExitCode = 1
            }

            Write-Host ""
        }
        elseif ($BitLockerStatus.ProtectionStatus -eq "Off") {
            Write-Host -Object "[Info] BitLocker is already suspended."
            Write-Host ""
        }
        #endregion

        try {
            # Calculate the reboot time (60 seconds from now).
            $RebootTime = (Get-Date).AddSeconds(60)
        }
        catch {
            Write-Host -Object "[Error] $($_.Exception.Message)"
            Write-Host -Object "[Error] Failed to add 60 seconds to the current date and time."
            $ExitCode = 1
        }

        Write-Host -Object "[Info] Scheduling reboot for $($RebootTime.ToShortDateString()) $($RebootTime.ToShortTimeString())."

        try {
            # Use shutdown.exe to schedule the reboot in 60 seconds.
            $RebootArguments = @(
                "/r"
                "/t 60"
            )
            Start-Process -FilePath "$env:WINDIR\System32\shutdown.exe" -ArgumentList $RebootArguments -NoNewWindow -Wait -ErrorAction Stop
        }
        catch {
            Write-Host -Object "[Error] $($_.Exception.Message)"
            Write-Host -Object "[Error] Failed to schedule the reboot."
            exit 1
        }
    }

    # If a reboot is required but the user did not specify to reboot if needed, warn the user
    if ($RebootRequired -and -not $SuspendBitLockerAndRebootIfNeeded) {
        Write-Host -Object "`n[Warning] A reboot is required to complete the installation of some updates, but the 'Suspend BitLocker and Reboot If Needed' option was not selected. Please reboot the system manually to complete the update process."
    }

    exit $ExitCode
}
end {
    
    
    
}