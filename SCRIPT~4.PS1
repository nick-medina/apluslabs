# ============================================================
# Script A - Workstation Onboarding
# Sierra Valley Unified School District
# Author: Nick Medina   IT100 Summer 2026
#
# Prepares a new staff workstation for deployment:
#   1. Renames the machine to the district naming standard
#   2. Sets DNS servers to the district domain controllers
#   3. Enables Windows Firewall on all three profiles
#   4. Disables 3 unnecessary services
#   5. Writes a completion report
#
# MUST be run from an elevated PowerShell session.
# EDIT THE FOUR VARIABLES BELOW BEFORE RUNNING.
# ============================================================

# ---------------------------------------- EDIT THESE
$SiteCode = 'HQ'          # HQ, CAMPUSB, or CAMPUSC
$AssetTag = '0142'        # District asset tag, 4 digits
$DnsPrimary = '10.1.60.10'
$DnsSecondary = '10.1.60.11'
# ---------------------------------------- END EDIT

$ReportDir = 'C:\Temp'
$NewName = "SVUSD-$SiteCode-$AssetTag"
$report = New-Object System.Collections.ArrayList
$errors = New-Object System.Collections.ArrayList
$RebootRequired = $false

function Add-Line { param([string]$Text = '') [void]$report.Add($Text); Write-Host $Text }
function Add-Ok { param([string]$Text) [void]$report.Add("  [ OK ] $Text"); Write-Host "  [ OK ] $Text" -ForegroundColor Green }
function Add-Fail { param([string]$Text) [void]$report.Add("  [FAIL] $Text"); [void]$errors.Add($Text); Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Add-Skip { param([string]$Text) [void]$report.Add("  [SKIP] $Text"); Write-Host "  [SKIP] $Text" -ForegroundColor Yellow }

Add-Line "============================================================"
Add-Line "         SVUSD WORKSTATION ONBOARDING"
Add-Line "============================================================"
Add-Line "Current name : $env:COMPUTERNAME"
Add-Line "Target name  : $NewName"
Add-Line "Technician   : $env:USERNAME"
Add-Line "Started      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "============================================================"
Add-Line ""

# ---------------------------------------- Pre-flight checks
Add-Line "[0] PRE-FLIGHT CHECKS"
Add-Line "------------------------------------------------------------"
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($id)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Error "This script must be run from an ELEVATED PowerShell session. Right-click PowerShell and choose Run as Administrator."
  return
}
Add-Ok "Session is elevated."
if ($AssetTag -notmatch '^\d{4}$') {
  Write-Error "AssetTag must be exactly 4 digits. Current value: $AssetTag"
  return
}
Add-Ok "Asset tag format is valid."
if ($SiteCode -notin @('HQ','CAMPUSB','CAMPUSC')) {
  Write-Error "SiteCode must be HQ, CAMPUSB, or CAMPUSC. Current value: $SiteCode"
  return
}
Add-Ok "Site code is valid."
if ($NewName.Length -gt 15) {
  Write-Error "Computer name '$NewName' exceeds the 15 character NetBIOS limit."
  return
}
Add-Ok "Name '$NewName' is within the 15 character NetBIOS limit."
Add-Line ""

# ---------------------------------------- 1. RENAME
Add-Line "[1] COMPUTER NAME"
Add-Line "------------------------------------------------------------"
if ($env:COMPUTERNAME -eq $NewName) {
  Add-Skip "Computer is already named $NewName. No change made."
} else {
  try {
    Rename-Computer -NewName $NewName -Force -ErrorAction Stop
    Add-Ok "Renamed from $env:COMPUTERNAME to $NewName. Takes effect after reboot."
    $RebootRequired = $true
  } catch {
    Add-Fail ("Rename failed: " + $_.Exception.Message)
  }
}
Add-Line ""

# ---------------------------------------- 2. DNS
Add-Line "[2] DNS CONFIGURATION"
Add-Line "------------------------------------------------------------"
try {
  $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false }
  if (-not $adapters) {
    Add-Fail "No active physical network adapters found."
  } else {
    foreach ($nic in $adapters) {
      try {
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($DnsPrimary, $DnsSecondary) -ErrorAction Stop
        Add-Ok ("$($nic.Name): DNS set to $DnsPrimary, $DnsSecondary")
      } catch {
        Add-Fail ("$($nic.Name): " + $_.Exception.Message)
      }
    }
    # Verify the change actually applied rather than trusting the cmdlet
    foreach ($nic in $adapters) {
      $current = (Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
      if ($current -contains $DnsPrimary) {
        Add-Ok ("$($nic.Name): verified, now reports " + ($current -join ', '))
      } else {
        Add-Fail ("$($nic.Name): verification failed, reports " + ($current -join ', '))
      }
    }
  }
} catch {
  Add-Fail ("DNS configuration error: " + $_.Exception.Message)
}
Add-Line ""

# ---------------------------------------- 3. FIREWALL
Add-Line "[3] WINDOWS FIREWALL"
Add-Line "------------------------------------------------------------"
foreach ($profileName in @('Domain','Private','Public')) {
  try {
    Set-NetFirewallProfile -Profile $profileName -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow -ErrorAction Stop
    $check = Get-NetFirewallProfile -Profile $profileName
    if ($check.Enabled) {
      Add-Ok "$profileName profile enabled, inbound default = Block."
    } else {
      Add-Fail "$profileName profile did not enable."
    }
  } catch {
    Add-Fail ("$profileName profile: " + $_.Exception.Message)
  }
}
Add-Line ""

# ---------------------------------------- 4. SERVICES
Add-Line "[4] DISABLE UNNECESSARY SERVICES"
Add-Line "------------------------------------------------------------"
# Three services disabled on every district staff workstation.
# Each is a genuine attack surface or bandwidth cost with no
# instructional or administrative use case at SVUSD.
$ServicesToDisable = @(
  @{ Name = 'RemoteRegistry'; Reason = 'Allows remote reading and writing of this registry. Used for lateral movement and reconnaissance. Nothing at SVUSD requires it.' },
  @{ Name = 'Fax';            Reason = 'Fax service. The district has no fax hardware attached to workstations.' },
  @{ Name = 'SSDPSRV';        Reason = 'UPnP device discovery. Generates broadcast traffic and exposes the host to network discovery. Not needed on a managed wired network.' }
)
foreach ($svc in $ServicesToDisable) {
  $name = $svc.Name
  try {
    $service = Get-Service -Name $name -ErrorAction Stop
    if ($service.Status -eq 'Running') {
      Stop-Service -Name $name -Force -ErrorAction Stop
    }
    Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
    $after = Get-Service -Name $name
    Add-Ok "$name stopped and set to Disabled. Status: $($after.Status)"
    Add-Line ("         Reason: " + $svc.Reason)
  } catch {
    if ($_.Exception.Message -match 'Cannot find any service') {
      Add-Skip "$name is not present on this build of Windows."
    } else {
      Add-Fail ("$name : " + $_.Exception.Message)
    }
  }
}
Add-Line ""

# ---------------------------------------- 5. COMPLETION REPORT
Add-Line "============================================================"
Add-Line "COMPLETION REPORT"
Add-Line "------------------------------------------------------------"
Add-Line "Target name       : $NewName"
Add-Line "DNS servers       : $DnsPrimary, $DnsSecondary"
Add-Line "Firewall profiles : Domain, Private, Public"
Add-Line "Services disabled : RemoteRegistry, Fax, SSDPSRV"
Add-Line "Finished          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line ""
if ($errors.Count -eq 0) {
  Add-Line "RESULT: SUCCESS. All onboarding tasks completed."
} else {
  Add-Line ("RESULT: COMPLETED WITH {0} ERROR(S):" -f $errors.Count)
  $n = 1
  foreach ($e in $errors) { Add-Line ("  {0}. {1}" -f $n, $e); $n++ }
}
Add-Line ""
if ($RebootRequired) {
  Add-Line "ACTION REQUIRED: reboot to apply the computer name change."
} else {
  Add-Line "No reboot required."
}
Add-Line "============================================================"

# ---------------------------------------- SAVE
try {
  if (-not (Test-Path -LiteralPath $ReportDir)) {
    New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null
  }
  $file = Join-Path $ReportDir ("onboarding_{0}_{1}.txt" -f $NewName, (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
  $report | Out-File -FilePath $file -Encoding UTF8
  Write-Host ""
  Write-Host "Report saved to: $file" -ForegroundColor Green
} catch {
  Write-Error ("Failed to save report: " + $_.Exception.Message)
}

if ($RebootRequired) {
  Write-Host ""
  Write-Host "Reboot now with:  Restart-Computer -Force" -ForegroundColor Yellow
}
