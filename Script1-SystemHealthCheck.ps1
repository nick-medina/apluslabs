# ============================================================
# Script 1 - System Health Check
# Author: Nick Medina   Course: IT100
# Checks: disk space (all drives), 30-second CPU average,
#         free memory, top 5 processes by CPU.
# Output: C:\Temp\healthcheck_[date].txt
# Thresholds: disk < 20% free, CPU avg > 80%, memory < 500 MB free
# Runtime: about 35 seconds (CPU is sampled for 30 of them)
# ============================================================
$DiskThresholdPct = 20
$CpuThresholdPct = 80
$CpuSampleSeconds = 30
$MemThresholdMB = 500
$ReportDir = 'C:\Temp'
$report = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
function Add-Line { param([string]$Text = '') [void]$report.Add($Text); Write-Host $Text }
function Add-Warn { param([string]$Text) [void]$warnings.Add($Text); [void]$report.Add("  >> WARNING: $Text"); Write-Host "  >> WARNING: $Text" -ForegroundColor Red }
Add-Line "============================================================"
Add-Line "               SYSTEM HEALTH CHECK REPORT"
Add-Line "============================================================"
Add-Line "Computer  : $env:COMPUTERNAME"
Add-Line "User      : $env:USERNAME"
Add-Line "Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "============================================================"
Add-Line ""
# ---------------------------------------- SECTION 1: DISK SPACE
Add-Line "[1] DISK SPACE - ALL FIXED DRIVES"
Add-Line "------------------------------------------------------------"
try {
  $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"
  foreach ($drive in $drives) {
    if ($drive.Size -gt 0) {
      $totalGB = [math]::Round($drive.Size/1GB,2)
      $freeGB = [math]::Round($drive.FreeSpace/1GB,2)
      $usedGB = [math]::Round($totalGB-$freeGB,2)
      $freePct = [math]::Round(($drive.FreeSpace/$drive.Size)*100,2)
      $label = $drive.VolumeName
      if (-not $label) { $label = '(no label)' }
      Add-Line ("Drive {0}  [{1}]" -f $drive.DeviceID, $label)
      Add-Line ("  Total : {0} GB" -f $totalGB)
      Add-Line ("  Used  : {0} GB" -f $usedGB)
      Add-Line ("  Free  : {0} GB ({1}%)" -f $freeGB, $freePct)
      if ($freePct -lt $DiskThresholdPct) {
        Add-Warn ("Drive {0} has only {1}% free (below {2}% threshold)." -f $drive.DeviceID, $freePct, $DiskThresholdPct)
      } else {
        Add-Line "  Status: OK"
      }
      Add-Line ""
    }
  }
} catch {
  Add-Line ("ERROR reading disks: " + $_.Exception.Message)
}
# ---------------------------------------- SECTION 2: CPU USAGE
Add-Line ("[2] CPU USAGE - {0} SECOND AVERAGE" -f $CpuSampleSeconds)
Add-Line "------------------------------------------------------------"
try {
  Write-Host ("Sampling CPU for {0} seconds, please wait..." -f $CpuSampleSeconds) -ForegroundColor Yellow
  $samples = Get-Counter -Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples $CpuSampleSeconds
  $values = $samples.CounterSamples | Select-Object -ExpandProperty CookedValue
  $avgCpu = [math]::Round(($values | Measure-Object -Average).Average,2)
  $maxCpu = [math]::Round(($values | Measure-Object -Maximum).Maximum,2)
  $minCpu = [math]::Round(($values | Measure-Object -Minimum).Minimum,2)
  Add-Line ("Samples taken : {0} (one per second)" -f $values.Count)
  Add-Line ("Average CPU   : {0}%" -f $avgCpu)
  Add-Line ("Peak CPU      : {0}%" -f $maxCpu)
  Add-Line ("Lowest CPU    : {0}%" -f $minCpu)
  if ($avgCpu -gt $CpuThresholdPct) {
    Add-Warn ("CPU averaged {0}% over {1} seconds (above {2}% threshold)." -f $avgCpu, $CpuSampleSeconds, $CpuThresholdPct)
  } else {
    Add-Line "Status        : OK"
  }
} catch {
  Add-Line ("ERROR sampling CPU: " + $_.Exception.Message)
}
Add-Line ""
# ---------------------------------------- SECTION 3: MEMORY
Add-Line "[3] PHYSICAL MEMORY"
Add-Line "------------------------------------------------------------"
try {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  $totalMB = [math]::Round($os.TotalVisibleMemorySize/1KB,2)
  $freeMB = [math]::Round($os.FreePhysicalMemory/1KB,2)
  $usedMB = [math]::Round($totalMB-$freeMB,2)
  $usedPct = [math]::Round(($usedMB/$totalMB)*100,2)
  Add-Line ("Total  : {0} MB ({1} GB)" -f $totalMB, [math]::Round($totalMB/1024,2))
  Add-Line ("Used   : {0} MB ({1}%)" -f $usedMB, $usedPct)
  Add-Line ("Free   : {0} MB" -f $freeMB)
  if ($freeMB -lt $MemThresholdMB) {
    Add-Warn ("Only {0} MB of memory free (below {1} MB threshold)." -f $freeMB, $MemThresholdMB)
  } else {
    Add-Line "Status : OK"
  }
} catch {
  Add-Line ("ERROR reading memory: " + $_.Exception.Message)
}
Add-Line ""
# ---------------------------------------- SECTION 4: TOP 5 PROCESSES
Add-Line "[4] TOP 5 PROCESSES BY CPU"
Add-Line "------------------------------------------------------------"
try {
  $topProcs = Get-Process | Where-Object { $_.CPU } | Sort-Object CPU -Descending | Select-Object -First 5 @{N='Name';E={$_.ProcessName}}, @{N='PID';E={$_.Id}}, @{N='CPU_Sec';E={[math]::Round($_.CPU,2)}}, @{N='Mem_MB';E={[math]::Round($_.WorkingSet64/1MB,2)}}
  if ($topProcs) {
    foreach ($line in (($topProcs | Format-Table -AutoSize | Out-String) -split "`r?`n")) {
      if ($line.Trim()) { Add-Line $line }
    }
  } else {
    Add-Line "No process CPU data available."
  }
} catch {
  Add-Line ("ERROR reading processes: " + $_.Exception.Message)
}
Add-Line ""
# ---------------------------------------- SUMMARY
Add-Line "============================================================"
Add-Line "SUMMARY"
Add-Line "------------------------------------------------------------"
if ($warnings.Count -eq 0) {
  Add-Line "No warnings. All checked values are within normal thresholds."
} else {
  Add-Line ("{0} warning(s) raised:" -f $warnings.Count)
  $n = 1
  foreach ($w in $warnings) { Add-Line ("  {0}. {1}" -f $n, $w); $n++ }
}
Add-Line "============================================================"
Add-Line "End of report"
Add-Line "============================================================"
# ---------------------------------------- SAVE REPORT
try {
  if (-not (Test-Path -LiteralPath $ReportDir)) {
    New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null
    Write-Host "Created folder $ReportDir" -ForegroundColor Yellow
  }
  $fullPath = Join-Path $ReportDir ("healthcheck_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd'))
  $report | Out-File -FilePath $fullPath -Encoding UTF8
  Write-Host ""
  Write-Host "Report saved to: $fullPath" -ForegroundColor Green
} catch {
  Write-Error ("Failed to save report: " + $_.Exception.Message)
}
