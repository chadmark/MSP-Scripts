<#
.SYNOPSIS
    Reports last logon time for all AD users with color-coded console output and Excel export.
.DESCRIPTION
    Queries Active Directory for all enabled users and their LastLogonDate.
    Outputs color-coded results to the console and exports to an Excel spreadsheet
    with conditional formatting. Requires the ImportExcel module.
.NOTES
    Author      : Chad
    Last Edit   : 04-17-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_ad_lastlogon_report.ps1
    Environment : Domain-joined Windows; run as Domain Admin or delegated AD read access
    Requires    : ActiveDirectory module, ImportExcel module
    Version     : 1.0
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

#region Config
$OutputPath   = "$env:USERPROFILE\Desktop\AD_LastLogon_$(Get-Date -Format 'yyyy-MM-dd').xlsx"
$ThresholdYellow = 30   # Days since last logon before turning yellow
$ThresholdRed    = 90   # Days since last logon before turning red
#endregion

#region Dependency Check
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host "ImportExcel module not found. Installing..." -ForegroundColor Yellow
    Install-Module -Name ImportExcel -Scope CurrentUser -Force
}
Import-Module ImportExcel
Import-Module ActiveDirectory
#endregion

#region Data Collection
Write-Host "`nQuerying Active Directory..." -ForegroundColor Cyan

$Users = Get-ADUser -Filter {Enabled -eq $true} -Properties DisplayName, SamAccountName, LastLogonDate, Title, Department |
    Select-Object @{N='Name';         E={$_.DisplayName}},
                  @{N='Username';     E={$_.SamAccountName}},
                  @{N='Title';        E={$_.Title}},
                  @{N='Department';   E={$_.Department}},
                  @{N='LastLogonDate';E={$_.LastLogonDate}},
                  @{N='DaysSinceLogon'; E={
                      if ($_.LastLogonDate) {
                          (New-TimeSpan -Start $_.LastLogonDate -End (Get-Date)).Days
                      } else { 'Never' }
                  }} |
    Sort-Object DaysSinceLogon -Descending
#endregion

#region Console Output
Write-Host "`n{'Color Key:',-20} Green = Active (<$ThresholdYellow days)  |  Yellow = Stale ($ThresholdYellow-$ThresholdRed days)  |  Red = Inactive (>$ThresholdRed days / Never)`n"

foreach ($User in $Users) {
    $days = $User.DaysSinceLogon
    $logon = if ($User.LastLogonDate) { $User.LastLogonDate.ToString('MM/dd/yyyy') } else { 'Never' }
    $line  = "{0,-30} {1,-20} {2,-22} {3}" -f $User.Name, $User.Username, $logon, $(if ($days -eq 'Never') { 'Never' } else { "$days days ago" })

    $color = if ($days -eq 'Never' -or $days -gt $ThresholdRed) {
        'Red'
    } elseif ($days -ge $ThresholdYellow) {
        'Yellow'
    } else {
        'Green'
    }

    Write-Host $line -ForegroundColor $color
}
#endregion

#region Excel Export
Write-Host "`nExporting to Excel: $OutputPath" -ForegroundColor Cyan

# Separate into buckets for conditional formatting row ranges
$ExcelData = $Users | Select-Object Name, Username, Title, Department, LastLogonDate, DaysSinceLogon

$ExcelData | Export-Excel -Path $OutputPath `
    -WorksheetName 'Last Logon Report' `
    -AutoSize `
    -AutoFilter `
    -FreezeTopRow `
    -BoldTopRow `
    -TableName 'LastLogonData' `
    -TableStyle Medium2 `
    -ConditionalText (
        # Red rows: Never logged in or > 90 days
        New-ConditionalText -Text 'Never' -BackgroundColor '#FFCCCC' -ConditionalTextColor '#CC0000',
        New-ConditionalText -Range 'F2:F9999' -ConditionType GreaterThan -ConditionValue $ThresholdRed `
            -BackgroundColor '#FFCCCC' -ConditionalTextColor '#CC0000',
        # Yellow rows: 30-90 days
        New-ConditionalText -Range 'F2:F9999' -ConditionType Between `
            -ConditionValue $ThresholdYellow -ConditionValue2 $ThresholdRed `
            -BackgroundColor '#FFF2CC' -ConditionalTextColor '#806000',
        # Green rows: < 30 days
        New-ConditionalText -Range 'F2:F9999' -ConditionType LessThan -ConditionValue $ThresholdYellow `
            -BackgroundColor '#CCFFCC' -ConditionalTextColor '#006100'
    )

Write-Host "Done. File saved to: $OutputPath`n" -ForegroundColor Green
#endregion
