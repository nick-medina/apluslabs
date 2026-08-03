# ============================================================
# Script 2 - User Account Report
# Author: Nick Medina   Course: IT100
# Lists all local user accounts with: name, enabled status,
# last logon, and whether the account is in Administrators.
# Flags any account that is ENABLED but has NEVER logged in.
# Output: C:\Temp\useraccounts_[date].csv
# ============================================================
$ReportDir = 'C:\Temp'
$results = New-Object System.Collections.ArrayList
$flagged = New-Object System.Collections.ArrayList
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                 USER ACCOUNT REPORT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Computer  : $env:COMPUTERNAME"
Write-Host "Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""
# ---------------------------------------- Check cmdlet availability
if (-not (Get-Command Get-LocalUser -ErrorAction SilentlyContinue)) {
  Write-Error "Get-LocalUser is not available on this system. Requires Windows 10 / Server 2016 or newer."
  return
}
# ---------------------------------------- Detect machine role
$roleText = 'Unknown'
$isDC = $false
try {
  $cs = Get-CimInstance Win32_ComputerSystem
  switch ($cs.DomainRole) {
    0 { $roleText = 'Standalone Workstation' }
    1 { $roleText = 'Member Workstation' }
    2 { $roleText = 'Standalone Server' }
    3 { $roleText = 'Member Server' }
    4 { $roleText = 'Backup Domain Controller'; $isDC = $true }
    5 { $roleText = 'Primary Domain Controller'; $isDC = $true }
  }
  Write-Host ("Machine role : {0}" -f $roleText)
  Write-Host ("Domain       : {0}" -f $cs.Domain)
} catch {
  Write-Warning "Could not determine machine role."
}
if ($isDC) { Write-Host "NOTE: On a domain controller there are no local groups. Accounts shown are DOMAIN accounts." -ForegroundColor Yellow }
Write-Host ""
# ---------------------------------------- Build Administrators lookup
# Three methods, tried in order, because the right one depends on machine role:
#   1. Get-LocalGroupMember  - works on workstations and member servers
#   2. Get-ADGroupMember     - works on domain controllers (AD module present by default)
#   3. ADSI WinNT provider   - last-resort fallback that works almost everywhere
$adminSids = @()
$adminSource = 'none'
try {
  $adminMembers = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop
  foreach ($m in $adminMembers) { $adminSids += $m.SID.Value }
  $adminSource = 'Get-LocalGroupMember'
} catch {
  try {
    if (Get-Command Get-ADGroupMember -ErrorAction SilentlyContinue) {
      $adminMembers = Get-ADGroupMember -Identity "Administrators" -Recursive -ErrorAction Stop
      foreach ($m in $adminMembers) { $adminSids += $m.SID.Value }
      $adminSource = 'Get-ADGroupMember (domain controller)'
    } else {
      throw "ActiveDirectory module not available"
    }
  } catch {
    try {
      $grp = [ADSI]("WinNT://" + $env:COMPUTERNAME + "/Administrators,group")
      $members = @($grp.Invoke("Members"))
      foreach ($m in $members) {
        $sidBytes = $m.GetType().InvokeMember("objectSid", "GetProperty", $null, $m, $null)
        $adminSids += (New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)).Value
      }
      $adminSource = 'ADSI WinNT provider'
    } catch {
      Write-Warning ("All three Administrators lookup methods failed: " + $_.Exception.Message)
    }
  }
}
Write-Host ("Admin lookup method : {0}" -f $adminSource) -ForegroundColor Yellow
Write-Host ("Administrator SIDs found : {0}" -f $adminSids.Count) -ForegroundColor Yellow
Write-Host ""
# ---------------------------------------- Collect user data
try {
  $users = Get-LocalUser -ErrorAction Stop
} catch {
  Write-Error ("Could not read local users: " + $_.Exception.Message)
  return
}
foreach ($u in $users) {
  $isAdmin = $adminSids -contains $u.SID.Value
  $neverLoggedIn = ($null -eq $u.LastLogon)
  if ($neverLoggedIn) { $lastLogonText = 'Never' } else { $lastLogonText = $u.LastLogon.ToString('yyyy-MM-dd HH:mm:ss') }
  if ($neverLoggedIn) { $daysSince = 'N/A' } else { $daysSince = [math]::Round(((Get-Date) - $u.LastLogon).TotalDays, 1) }
  if ($null -eq $u.PasswordLastSet) { $pwdSetText = 'Never' } else { $pwdSetText = $u.PasswordLastSet.ToString('yyyy-MM-dd') }
  $flag = ''
  if ($u.Enabled -and $neverLoggedIn) {
    $flag = 'REVIEW: enabled but never logged in'
    if ($isAdmin) { $flag = 'HIGH RISK: enabled admin, never logged in' }
    [void]$flagged.Add($u.Name)
  }
  $row = [PSCustomObject][ordered]@{
    UserName       = $u.Name
    Enabled        = $u.Enabled
    LastLogon      = $lastLogonText
    DaysSinceLogon = $daysSince
    IsAdmin        = $isAdmin
    NeverLoggedIn  = $neverLoggedIn
    PasswordLastSet = $pwdSetText
    Description    = $u.Description
    SID            = $u.SID.Value
    Flag           = $flag
  }
  [void]$results.Add($row)
}
# ---------------------------------------- Console output
Write-Host "ALL LOCAL USER ACCOUNTS" -ForegroundColor White
Write-Host "------------------------------------------------------------"
$results | Format-Table UserName, Enabled, LastLogon, IsAdmin, Flag -AutoSize
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------"
Write-Host ("Machine role            : {0}" -f $roleText)
Write-Host ("Admin lookup method     : {0}" -f $adminSource)
Write-Host ("Total accounts          : {0}" -f $results.Count)
Write-Host ("Enabled accounts        : {0}" -f (@($results | Where-Object { $_.Enabled }).Count))
Write-Host ("Disabled accounts       : {0}" -f (@($results | Where-Object { -not $_.Enabled }).Count))
Write-Host ("Administrator accounts  : {0}" -f (@($results | Where-Object { $_.IsAdmin }).Count))
Write-Host ("Never logged in         : {0}" -f (@($results | Where-Object { $_.NeverLoggedIn }).Count))
Write-Host ""
if ($flagged.Count -eq 0) {
  Write-Host "No flagged accounts. No enabled account is sitting unused." -ForegroundColor Green
} else {
  Write-Host ("{0} FLAGGED ACCOUNT(S) - enabled but never logged in:" -f $flagged.Count) -ForegroundColor Red
  foreach ($f in $flagged) {
    $detail = $results | Where-Object { $_.UserName -eq $f }
    Write-Host ("  - {0}  ({1})" -f $f, $detail.Flag) -ForegroundColor Red
  }
  Write-Host ""
  Write-Host "Enabled accounts that have never been used are a common attack surface." -ForegroundColor Yellow
  Write-Host "Recommended action: disable them or confirm they are needed." -ForegroundColor Yellow
}
Write-Host "============================================================" -ForegroundColor Cyan
# ---------------------------------------- Export CSV
try {
  if (-not (Test-Path -LiteralPath $ReportDir)) {
    New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null
    Write-Host "Created folder $ReportDir" -ForegroundColor Yellow
  }
  $csvPath = Join-Path $ReportDir ("useraccounts_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd'))
  $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
  Write-Host ""
  Write-Host "CSV saved to: $csvPath" -ForegroundColor Green
} catch {
  Write-Error ("Failed to save CSV: " + $_.Exception.Message)
}
