<#
.SYNOPSIS
    Disables Microsoft Edge's First Run Experience and Windows "recommendations" prompts.
.DESCRIPTION
    Sets two registry values:
      - HideFirstRunExperience = 1 under the Edge policy key, suppressing Edge's
        first-run welcome/setup screens.
      - ShowRecommendationsEnabled = 0 under UserProfileEngagement, suppressing
        Windows "suggestions"/recommendation prompts tied to first sign-in.
    Creates each key if missing. Checks each value individually and skips setting
    it if it's already present with the desired data, so re-runs are safe no-ops.
    Both values are under HKLM, so this is machine-wide (applies to all users on
    the device, not just the account it's run under). This is a one-time,
    run-once script — intended for onboarding new PCs via Ninja. No recurring
    schedule or repeat runs are needed once it has been applied.
.NOTES
    Author      : Chad
    Last Edit   : 08-21-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/BrowserRelated/ninja_disable_edge_firstrun_recommendations.ps1
    Environment : Windows endpoints with Microsoft Edge installed
    Requires    : Local admin rights (writes to HKLM)
    Version     : 1.0
    Ninja Note  : No script variables required.
.CHANGELOG
    1.0 - 08-21-2026 - Initial version
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# Define registry paths and keys
$regValues = @{
    "HKLM:\SOFTWARE\Policies\Microsoft\Edge" = @{ "HideFirstRunExperience" = 1 }
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement" = @{ "ShowRecommendationsEnabled" = 0 }
}

# Create registry paths and set values
foreach ($path in $regValues.Keys) {
    if (-not (Test-Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }

    foreach ($name in $regValues[$path].Keys) {
        $desiredValue = $regValues[$path][$name]
        $existing = Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue

        if ($existing -and $existing.$name -eq $desiredValue) {
            Write-Host "Value '$name' already set to '$desiredValue' under '$path'. Skipping."
            continue
        }

        Set-ItemProperty -Path $path -Name $name -Value $desiredValue -Force
        Write-Host "Set '$name' to '$desiredValue' under '$path'."
    }
}

Write-Output "Microsoft Edge First Run Experience and recommendations have been disabled."
