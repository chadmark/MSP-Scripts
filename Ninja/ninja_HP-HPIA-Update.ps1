<#
.SYNOPSIS
    Updates HP drivers, BIOS, and firmware using HP Image Assistant (HPIA).
.DESCRIPTION
    Checks if the system manufacturer is HP. If so, downloads and installs HP Image
    Assistant (HPIA) if not already present, then runs an analyze-and-install operation
    targeting BIOS, Drivers, and Firmware. Results are parsed from the HPIA XML report
    and written to the console. Working files and logs are stored under C:\temp\BrightFlow\HPIA.
.NOTES
    Author      : Chad
    Last Edit   : 05-06-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_HP-HPIA-Update.ps1
    Environment : NinjaOne RMM — runs as SYSTEM on domain-joined HP endpoints
    Requires    : Internet access to ftp.ext.hp.com and hpia.hpcloud.hp.com
    Version     : 1.0
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# Check if manufacturer is HP
$Manufacturer = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty Manufacturer
if (($Manufacturer -eq "HP") -or ($Manufacturer -like "Hewlett*")) {
	# Establish directories
	$hpiaDirectory = "C:\temp\BrightFlow\HPIA"
	$hpiaLogs = "C:\temp\BrightFlow\Logs\HPIA"
	if (-not(Test-Path $hpiaDirectory)) { New-Item -ItemType Directory $hpiaDirectory | Out-Null }
	if (-not(Test-Path $hpiaLogs)) { New-Item -ItemType Directory $hpiaLogs | Out-Null }
	# Run HPIA and return the results
	function Invoke-HPImageAssistant {
		Write-Host "|| Running HP Image Assistant..."
		& "$hpiaDirectory\HPImageAssistant.exe" /Operation:Analyze /Category:BIOS,Drivers,Firmware /Selection:All /Action:Install /SoftpaqDownloadFolder:$hpiaDirectory /Silent /ReportFolder:$hpiaLogs
		while (-not(Test-Path "$hpiaLogs\*.xml")) { Start-Sleep -Seconds 60 }
		$Directories = @("BIOS","Drivers","Firmware")
		$Results = [System.Collections.Generic.List[object]]::New()
		foreach ($directory in $Directories) {
			$updates = ([xml](Get-Content "$hpiaLogs\*.xml")).HPIA.Recommendations.$directory.Recommendation | ForEach-Object {
				if (-not([string]::IsNullOrWhitespace(($_)))) {
					$CurrentVersion = $_.TargetVersion
					$UpdatedVersion = $_.ReferenceVersion
					"[$($_.Solution.Softpaq.Id)] $($_.Solution.Softpaq.Name), Version $UpdatedVersion (Current: $CurrentVersion)"
					"- $($_.Solution.Softpaq.URL)"
				}
			}
			$Results.Add($updates)
		}
		if (-not([string]::IsNullOrWhitespace($Results))) {
			Write-Host "|| - Found available updates:`n"
			$Results
		} else { Write-Host "|| - No updates found." }
	}
	if (Test-Path "$hpiaDirectory\HPImageAssistant.exe") {
		 # TODO // Check for available updates
		 
		# Run HP Image Assistant if it's already installed
		Invoke-HPImageAssistant
	} else {
		# Download HP Image Assistant
		#Retrieve newest installer
		$hpia_WR = Invoke-WebRequest -Uri "https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html" -UseBasicParsing
		$hpia_DownloadURL = $hpia_WR.Links | Where-Object href -Like "https://hpia.hpcloud.hp.com/downloads/hpia/*" | Select-Object -ExpandProperty href
		if (-not($hpia_DownloadURL)) { $hpia_DownloadURL = "https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.4.exe" } # Fallback URL
		$hpia_InstallFileName = [System.IO.Path]::GetFileName($hpia_DownloadURL)
		$hpia_AvailableVersion = $hpia_InstallFileName -replace "hp-hpia-" -replace ".exe"
		
		#Download installer
		Write-Host "|| Downloading HPIA installer..."
		Add-Type -AssemblyName System.Web
		[Net.ServicePointManager]::SecurityProtocol = "Tls12"
		$hpia_installer = "$hpiaDirectory\$hpia_InstallFileName"
		(New-Object net.webclient).DownloadFile($hpia_DownloadURL,$hpia_installer)
		if (Test-Path $hpia_installer) {
			Write-Host "|| - Successfully downloaded installer."
			# Install HP Image Assistant
			Write-Host "|| Installing HPIA..."
			& $hpia_installer /s /e /f $hpiaDirectory
			Start-Sleep -Seconds 5
			if (Test-Path "$hpiaDirectory\HPImageAssistant.exe") {
				Write-Host "|| - Successfully installed HPIA."
				# Run HP Image Assistant
				Invoke-HPImageAssistant
			} else { Write-Host ">> - Failed to install HPIA." }
		} else { Write-Host ">> - Failed to download installer." }
	}
} else { Write-Host ">> HP Image Assistant not compatible with this system." }
