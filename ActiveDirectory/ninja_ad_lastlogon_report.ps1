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
    Version     : 1.1
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

#region Config
$OutputPath      = "c:\temp\AD_LastLogon_$(Get-Date -Format 'MM-dd-yyyy').xlsx"
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
    Select-Object @{N='Name';           E={$_.DisplayName}},
                  @{N='Username';       E={$_.SamAccountName}},
                  @{N='Title';          E={$_.Title}},
                  @{N='Department';     E={$_.Department}},
                  @{N='LastLogonDate';  E={if ($_.LastLogonDate) { $_.LastLogonDate.ToString('MM/dd/yyyy') } else { 'Never' }}},
                  @{N='DaysSinceLogon'; E={
                      if ($_.LastLogonDate) {
                          (New-TimeSpan -Start $_.LastLogonDate -End (Get-Date)).Days
                      } else { 999 }
                  }} |
    Sort-Object DaysSinceLogon -Descending
#endregion

#region Console Output
Write-Host "`nColor Key: Green = Active (<$ThresholdYellow days)  |  Yellow = Stale ($ThresholdYellow-$ThresholdRed days)  |  Red = Inactive (>$ThresholdRed days / Never)`n"

foreach ($User in $Users) {
    $days  = $User.DaysSinceLogon
    $label = if ($days -eq 999) { 'Never' } else { "$days days ago" }
    $line  = "{0,-30} {1,-20} {2,-15} {3}" -f $User.Name, $User.Username, $User.LastLogonDate, $label

    $color = if ($days -gt $ThresholdRed) {
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

$ExcelData = $Users | Select-Object Name, Username, Title, Department, LastLogonDate, DaysSinceLogon

$ExcelPkg = $ExcelData | Export-Excel -Path $OutputPath `
    -WorksheetName 'Last Logon Report' `
    -AutoSize `
    -AutoFilter `
    -FreezeTopRow `
    -BoldTopRow `
    -TableName 'LastLogonData' `
    -TableStyle Medium2 `
    -PassThru

$Sheet    = $ExcelPkg.Workbook.Worksheets['Last Logon Report']
$LastRow  = $Sheet.Dimension.End.Row
$DataRange = "F2:F$LastRow"

# Red: > 90 days (includes 999 placeholder for Never)
Add-ConditionalFormatting -Worksheet $Sheet -Range $DataRange `
    -RuleType GreaterThan -ConditionValue $ThresholdRed `
    -BackgroundColor '#FFCCCC' -ForegroundColor '#CC0000'

# Yellow: 30-90 days
Add-ConditionalFormatting -Worksheet $Sheet -Range $DataRange `
    -RuleType Between -ConditionValue $ThresholdYellow -ConditionValue2 $ThresholdRed `
    -BackgroundColor '#FFF2CC' -ForegroundColor '#806000'

# Green: < 30 days
Add-ConditionalFormatting -Worksheet $Sheet -Range $DataRange `
    -RuleType LessThan -ConditionValue $ThresholdYellow `
    -BackgroundColor '#CCFFCC' -ForegroundColor '#006100'

Close-ExcelPackage $ExcelPkg -SaveAs $OutputPath

Write-Host "Done. File saved to: $OutputPath`n" -ForegroundColor Green
#endregion
