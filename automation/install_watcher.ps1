param(
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

$taskName = 'PingPlaceWatcher'
$scriptPath = Join-Path $PSScriptRoot 'run_watcher.ps1'
$python = Get-Command python -ErrorAction Stop
$start = (Get-Date).AddMinutes(1)
$repeat = New-TimeSpan -Minutes 15
$duration = New-TimeSpan -Days 3650
$userId = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval $repeat -RepetitionDuration $duration
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -WakeToRun:$false -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

if ($action.Execute -ne 'PowerShell.exe' -or $action.Arguments -notmatch [regex]::Escape("`"$scriptPath`"")) {
    throw 'Validation failed: scheduled action does not quote run_watcher.ps1'
}
if ([System.Xml.XmlConvert]::ToTimeSpan($trigger.Repetition.Interval) -ne $repeat) {
    throw 'Validation failed: repetition interval is not 15 minutes'
}
if ($settings.MultipleInstances -ne 'IgnoreNew' -or $settings.WakeToRun) {
    throw 'Validation failed: overlap or wake settings are unsafe'
}
if ($principal.UserId -ne $userId -or $principal.LogonType -ne 'Interactive' -or $principal.RunLevel -ne 'Limited') {
    throw 'Validation failed: task principal is not the current limited interactive user'
}

if ($ValidateOnly) {
    Write-Host 'Validation passed; no scheduled task was installed.'
    Write-Host "  Script:             $scriptPath"
    Write-Host '  Schedule:           every 15 minutes'
    Write-Host "  Run as:             $userId"
    Write-Host '  Multiple instances: IgnoreNew'
    Write-Host '  Wake the computer:  disabled'
    exit 0
}

Write-Host "Planned Task Scheduler installation:"
Write-Host "  Name:                 $taskName"
Write-Host "  Action:               PowerShell -> $scriptPath"
Write-Host "  Python:               $($python.Source)"
Write-Host "  Schedule:             every 15 minutes"
Write-Host "  Run as:               $userId (normal user)"
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

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Installed $taskName. Verify it with: Get-ScheduledTask -TaskName $taskName"
