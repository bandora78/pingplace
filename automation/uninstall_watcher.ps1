$ErrorActionPreference = 'Stop'
$taskName = 'PingPlaceWatcher'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -eq $existing) {
    Write-Host "$taskName is not installed."
    exit 0
}
$confirmation = Read-Host "Type UNINSTALL to remove $taskName"
if ($confirmation -cne 'UNINSTALL') {
    Write-Host 'Uninstall cancelled.'
    exit 1
}
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
Write-Host "Removed $taskName. Local logs/state under %LOCALAPPDATA%\PingPlaceWatcher were preserved."
