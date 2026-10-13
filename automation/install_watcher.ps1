$ErrorActionPreference = 'Stop'

$taskName = 'PingPlaceWatcher'
$scriptPath = Join-Path $PSScriptRoot 'run_watcher.ps1'
$python = Get-Command python -ErrorAction Stop
$start = (Get-Date).AddMinutes(1)
$repeat = New-TimeSpan -Minutes 15
$duration = New-TimeSpan -Days 3650

Write-Host "Planned Task Scheduler installation:"
Write-Host "  Name:                 $taskName"
Write-Host "  Action:               PowerShell -> $scriptPath"
Write-Host "  Python:               $($python.Source)"
Write-Host "  Schedule:             every 15 minutes"
Write-Host "  Run as:               $env:USERDOMAIN\$env:USERNAME (normal user)"
Write-Host "  Multiple instances:   IgnoreNew"
Write-Host "  Wake the computer:    disabled"
Write-Host "  Missed runs:          StartWhenAvailable after logon"
Write-Host ""
Write-Host "This installs only the read-only Stage B watcher. It does not dispatch Codex or modify GitHub."
$confirmation = Read-Host "Type INSTALL to continue"
if ($confirmation -cne 'INSTALL') {
    Write-Host 'Installation cancelled.'
    exit 1
}

$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval $repeat -RepetitionDuration $duration
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -WakeToRun:$false -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType InteractiveToken -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Installed $taskName. Verify it with: Get-ScheduledTask -TaskName $taskName"
