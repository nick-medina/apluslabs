# ============================================================
# Script 3 - Event Log Parser
# Author: Nick Medina   Course: IT100
# Section 1: System log - Error events in the last 24 hours
# Section 2: Security log - Event ID 4625 (failed logon), last 24 hours
# Output: single text report at C:\Temp\eventlog_report_[date].txt
# NOTE: Reading the Security log requires an elevated session.
# ============================================================
$ReportDir = 'C:\Temp'
$HoursBack = 24
$MaxDetail = 100
$StartTime = (Get-Date).AddHours(-$HoursBack)
$report = New-Object System.Collections.ArrayList
function Add-Line { param([string]$Text = '') [void]$report.Add($Text); Write-Host $Text }
function Get-EventData { param($EventRecord, [string]$FieldName)
  try {
    $xml = [xml]$EventRecord.ToXml()
    $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $FieldName }
    if ($node) { return [string]$node.'#text' }
    return ''
  } catch {
    return ''
  }
}
function Convert-LogonType { param([string]$Code)
  switch ($Code) {
    '2'  { return 'Interactive (console)' }
    '3'  { return 'Network (share/SMB)' }
    '4'  { return 'Batch (scheduled task)' }
    '5'  { return 'Service' }
    '7'  { return 'Unlock workstation' }
    '8'  { return 'NetworkCleartext' }
    '9'  { return 'NewCredentials (runas)' }
    '10' { return 'RemoteInteractive (RDP)' }
    '11' { return 'CachedInteractive' }
    default { return "Type $Code" }
  }
}
# ---------------------------------------- Header
Add-Line "============================================================"
Add-Line "                 EVENT LOG REPORT"
Add-Line "============================================================"
Add-Line "Computer    : $env:COMPUTERNAME"
Add-Line "Generated   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line ("Window      : last {0} hours" -f $HoursBack)
Add-Line ("Range start : {0}" -f $StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
Add-Line ("Range end   : {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Add-Line "============================================================"
Add-Line ""
# ---------------------------------------- Elevation check
$isAdmin = $false
try {
  $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
  $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
  $isAdmin = $false
}
if ($isAdmin) {
  Add-Line "Session is elevated. Security log access should succeed."
} else {
  Add-Line "WARNING: session is NOT elevated. The Security log may be unreadable."
}
Add-Line ""
# ================================================================
# SECTION 1 - SYSTEM LOG ERRORS
# ================================================================
Add-Line "============================================================"
Add-Line ("[1] SYSTEM LOG - ERROR EVENTS (LAST {0} HOURS)" -f $HoursBack)
Add-Line "============================================================"
$sysErrors = @()
try {
  $sysErrors = @(Get-WinEvent -FilterHashtable @{LogName='System'; Level=2; StartTime=$StartTime} -ErrorAction Stop)
} catch {
  if ($_.Exception.Message -match 'No events were found') {
    Add-Line "No Error events found in the System log for this period."
  } else {
    Add-Line ("ERROR querying System log: " + $_.Exception.Message)
  }
}
if ($sysErrors.Count -gt 0) {
  Add-Line ("Total Error events found: {0}" -f $sysErrors.Count)
  Add-Line ""
  Add-Line "--- Summary grouped by source and event ID ---"
  $grouped = $sysErrors | Group-Object ProviderName, Id | Sort-Object Count -Descending
  foreach ($g in $grouped) {
    $first = $g.Group[0]
    Add-Line ("  {0,4} x  Source: {1}  (Event ID {2})" -f $g.Count, $first.ProviderName, $first.Id)
  }
  Add-Line ""
  Add-Line "--- Detailed entries (newest first) ---"
  Add-Line ""
  $shown = 0
  foreach ($e in ($sysErrors | Sort-Object TimeCreated -Descending)) {
    if ($shown -ge $MaxDetail) { break }
    $msg = $e.Message
    if (-not $msg) { $msg = '(no message text)' }
    $msg = ($msg -replace "`r`n", ' ' -replace "`n", ' ').Trim()
    if ($msg.Length -gt 250) { $msg = $msg.Substring(0,250) + '...' }
    Add-Line ("[{0}]  ID {1}  Source: {2}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $e.Id, $e.ProviderName)
    Add-Line ("     {0}" -f $msg)
    Add-Line ""
    $shown++
  }
  if ($sysErrors.Count -gt $MaxDetail) {
    Add-Line ("... {0} additional entries not shown (detail capped at {1})." -f ($sysErrors.Count - $MaxDetail), $MaxDetail)
    Add-Line ""
  }
}
# ================================================================
# SECTION 2 - SECURITY LOG FAILED LOGONS (4625)
# ================================================================
Add-Line "============================================================"
Add-Line ("[2] SECURITY LOG - FAILED LOGONS, EVENT ID 4625 (LAST {0} HOURS)" -f $HoursBack)
Add-Line "============================================================"
$failedLogons = @()
$securityReadable = $true
try {
  $failedLogons = @(Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4625; StartTime=$StartTime} -ErrorAction Stop)
} catch {
  if ($_.Exception.Message -match 'No events were found') {
    Add-Line "No failed logon events (4625) found for this period."
  } elseif ($_.Exception.Message -match 'Attempted to perform an unauthorized operation') {
    Add-Line "ACCESS DENIED reading the Security log. Re-run this script from an elevated session."
    $securityReadable = $false
  } else {
    Add-Line ("ERROR querying Security log: " + $_.Exception.Message)
    $securityReadable = $false
  }
}
if ($failedLogons.Count -gt 0) {
  Add-Line ("Total failed logon attempts: {0}" -f $failedLogons.Count)
  Add-Line ""
  Add-Line "--- Failed attempts grouped by target account ---"
  $byUser = $failedLogons | ForEach-Object { Get-EventData -EventRecord $_ -FieldName 'TargetUserName' } | Group-Object | Sort-Object Count -Descending
  foreach ($g in $byUser) {
    $uname = $g.Name
    if (-not $uname) { $uname = '(blank)' }
    Add-Line ("  {0,4} x  Account: {1}" -f $g.Count, $uname)
  }
  Add-Line ""
  Add-Line "--- Failed attempts grouped by source IP ---"
  $byIp = $failedLogons | ForEach-Object { Get-EventData -EventRecord $_ -FieldName 'IpAddress' } | Group-Object | Sort-Object Count -Descending
  foreach ($g in $byIp) {
    $ip = $g.Name
    if (-not $ip -or $ip -eq '-') { $ip = '(local / not recorded)' }
    Add-Line ("  {0,4} x  Source IP: {1}" -f $g.Count, $ip)
  }
  Add-Line ""
  Add-Line "--- Detailed entries (newest first) ---"
  Add-Line ""
  $shown = 0
  foreach ($e in ($failedLogons | Sort-Object TimeCreated -Descending)) {
    if ($shown -ge $MaxDetail) { break }
    $targetUser = Get-EventData -EventRecord $e -FieldName 'TargetUserName'
    $targetDom = Get-EventData -EventRecord $e -FieldName 'TargetDomainName'
    $srcIp = Get-EventData -EventRecord $e -FieldName 'IpAddress'
    $srcWks = Get-EventData -EventRecord $e -FieldName 'WorkstationName'
    $logonTy = Get-EventData -EventRecord $e -FieldName 'LogonType'
    $procName = Get-EventData -EventRecord $e -FieldName 'ProcessName'
    if (-not $targetUser) { $targetUser = '(blank)' }
    if (-not $srcIp -or $srcIp -eq '-') { $srcIp = '(not recorded)' }
    if (-not $srcWks) { $srcWks = '(not recorded)' }
    Add-Line ("[{0}]  FAILED LOGON" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))
    Add-Line ("     Target account : {0}\{1}" -f $targetDom, $targetUser)
    Add-Line ("     Logon type     : {0}" -f (Convert-LogonType -Code $logonTy))
    Add-Line ("     Source IP      : {0}" -f $srcIp)
    Add-Line ("     Workstation    : {0}" -f $srcWks)
    Add-Line ("     Process        : {0}" -f $procName)
    Add-Line ""
    $shown++
  }
  if ($failedLogons.Count -gt $MaxDetail) {
    Add-Line ("... {0} additional entries not shown (detail capped at {1})." -f ($failedLogons.Count - $MaxDetail), $MaxDetail)
    Add-Line ""
  }
}
# ================================================================
# SUMMARY
# ================================================================
Add-Line "============================================================"
Add-Line "SUMMARY"
Add-Line "------------------------------------------------------------"
Add-Line ("Reporting window        : last {0} hours" -f $HoursBack)
Add-Line ("System log errors       : {0}" -f $sysErrors.Count)
if ($securityReadable) {
  Add-Line ("Failed logons (4625)    : {0}" -f $failedLogons.Count)
} else {
  Add-Line "Failed logons (4625)    : UNAVAILABLE (access denied)"
}
Add-Line ""
if ($sysErrors.Count -eq 0 -and $failedLogons.Count -eq 0 -and $securityReadable) {
  Add-Line "No errors and no failed logons in the reporting window."
} else {
  if ($sysErrors.Count -gt 0) {
    $topSource = ($sysErrors | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 1)
    Add-Line ("Most frequent error source: {0} ({1} events)" -f $topSource.Name, $topSource.Count)
  }
  if ($failedLogons.Count -gt 0) {
    Add-Line "Review the failed logon section for repeated attempts against a single account,"
    Add-Line "which can indicate password guessing or a brute force attempt."
  }
}
Add-Line "============================================================"
Add-Line "End of report"
Add-Line "============================================================"
# ---------------------------------------- Save report
try {
  if (-not (Test-Path -LiteralPath $ReportDir)) {
    New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null
    Write-Host "Created folder $ReportDir" -ForegroundColor Yellow
  }
  $outPath = Join-Path $ReportDir ("eventlog_report_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd'))
  $report | Out-File -FilePath $outPath -Encoding UTF8
  Write-Host ""
  Write-Host "Report saved to: $outPath" -ForegroundColor Green
} catch {
  Write-Error ("Failed to save report: " + $_.Exception.Message)
}
